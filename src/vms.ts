import { DurableObject } from 'cloudflare:workers';

export type VmFlavor = 'ubuntu' | 'nixos';

export type VmCommandResult = {
  command: string[];
  exitCode: number;
  stdout: string;
  stderr: string;
};

export type VmInfo = {
  name: string;
  flavor: VmFlavor | null;
  running: boolean;
  containerId: string | null;
  createdAt: string | null;
  osRelease: string | null;
  kernel: string | null;
  pid1: string | null;
  systemState: string | null;
};

const UBUNTU_IMAGE_NAME = 'ubuntu';
const NIXOS_IMAGE_NAME = 'nixos';
const READY_ATTEMPTS = 120;
const VM_INACTIVITY_TIMEOUT_MS = 30 * 60 * 1000;
const decoder = new TextDecoder();

const ubuntuShell = ['/bin/sh', '-c'];

export class VirtualMachine extends DurableObject<Env> {
  async listNames(): Promise<string[]> {
    return (await this.ctx.storage.get<string[]>('registry:names')) ?? [];
  }

  async setNames(names: string[]): Promise<void> {
    await this.ctx.storage.put('registry:names', names);
  }

  async create(name: string, flavor: VmFlavor): Promise<VmInfo> {
    const container = this.requireContainer();
    if (!container.running) {
      if (flavor === 'nixos') {
        container.start({
          image: container.images[NIXOS_IMAGE_NAME],
          entrypoint: ['/boot-probe'],
          enableInternet: false,
          instance: 'standard-1',
        });
      } else {
        container.start({
          image: container.images[UBUNTU_IMAGE_NAME],
          entrypoint: ['/bin/sleep', 'infinity'],
          enableInternet: false,
          instance: 'lite',
        });
      }
      await container.setInactivityTimeout(VM_INACTIVITY_TIMEOUT_MS);
      await this.ctx.storage.put({ name, flavor, createdAt: new Date().toISOString() });
    }
    await this.waitForExec(flavor);
    return this.info();
  }

  async info(): Promise<VmInfo> {
    const container = this.requireContainer();
    const [name, flavor, createdAt] = await Promise.all([
      this.ctx.storage.get<string>('name'),
      this.ctx.storage.get<VmFlavor>('flavor'),
      this.ctx.storage.get<string>('createdAt'),
    ]);
    const base: VmInfo = {
      name: name ?? 'unknown',
      flavor: flavor ?? null,
      running: container.running,
      containerId: null,
      createdAt: createdAt ?? null,
      osRelease: null,
      kernel: null,
      pid1: null,
      systemState: null,
    };
    if (!container.running || !flavor) {
      return base;
    }
    if (flavor === 'nixos') {
      return { ...base, ...(await this.nixosFacts()) };
    }
    const facts = await this.shell(flavor, [
      'cat /proc/sys/kernel/hostname',
      'grep -E "^(ID|PRETTY_NAME)=" /etc/os-release | tr "\\n" " "',
      'echo',
      'uname -r',
      'cat /proc/1/comm',
      'echo n/a',
    ].join('; '));
    const [hostname, osRelease, kernel, pid1, systemState] = facts.stdout.split('\n').map((line) => line.trim());
    return {
      ...base,
      containerId: hostname || null,
      osRelease: osRelease ?? null,
      kernel: kernel ?? null,
      pid1: pid1 ?? null,
      systemState: systemState ?? null,
    };
  }

  private async nixosFacts(): Promise<Partial<VmInfo>> {
    const report = await this.bootReport();
    const section = (name: string): string => {
      const start = report.indexOf(`--- ${name} ---`);
      if (start < 0) return '';
      const rest = report.slice(start + name.length + 8);
      const end = rest.indexOf('\n--- ');
      return (end < 0 ? rest : rest.slice(0, end)).trim();
    };
    const processes = section('processes').split('\n');
    const pid1Line = processes.find((line) => line.startsWith('1 ')) ?? '';
    const pid1Command = pid1Line.slice(2).trim().split(' ')[0] ?? '';
    const preflight = report.slice(0, report.indexOf('--- systemd console ---'));
    const field = (key: string): string => preflight.match(new RegExp(`^${key}=(.*)$`, 'm'))?.[1]?.trim() ?? '';
    return {
      containerId: field('hostname') || null,
      osRelease: field('os_release') || null,
      kernel: field('kernel') || null,
      pid1: pid1Command.split('/').pop() || null,
      systemState: section('systemctl').split('\n')[0] || null,
    };
  }

  private async bootReport(): Promise<string> {
    const port = this.requireContainer().getTcpPort(8080);
    await (await port.fetch('http://vm/')).text();
    await scheduler.wait(1500);
    return (await port.fetch('http://vm/')).text();
  }

  async exec(command: string): Promise<VmCommandResult> {
    const flavor = await this.ctx.storage.get<VmFlavor>('flavor');
    if (!flavor || !this.requireContainer().running) {
      throw new Error('vm is not running');
    }
    if (flavor === 'nixos') {
      throw new Error('exec into a NixOS vm is not supported yet: Cloudflare exec fails on custom-entrypoint containers (see receipts/BLOCKERS.md)');
    }
    return this.shell(flavor, command);
  }

  async destroy(): Promise<{ destroyed: boolean }> {
    const container = this.requireContainer();
    if (container.running) {
      await container.destroy('vm destroyed');
    }
    await this.ctx.storage.deleteAll();
    return { destroyed: true };
  }

  private async shell(flavor: VmFlavor, command: string): Promise<VmCommandResult> {
    const argv = [...ubuntuShell, command];
    const env: Record<string, string> =
      flavor === 'nixos'
        ? { PATH: '/run/current-system/sw/bin:/nixos-system/sw/bin', HOME: '/root' }
        : { PATH: '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin', HOME: '/root' };
    const process = await this.requireContainer().exec(argv, { env });
    const output = await process.output();
    return {
      command: argv,
      exitCode: output.exitCode,
      stdout: decoder.decode(output.stdout),
      stderr: decoder.decode(output.stderr),
    };
  }

  private async waitForExec(flavor: VmFlavor): Promise<void> {
    for (let attempt = 0; attempt < READY_ATTEMPTS; attempt++) {
      if (flavor === 'nixos') {
        try {
          const report = await this.bootReport();
          if (report.includes('--- systemctl ---') && /^1 \S*systemd/m.test(report)) {
            return;
          }
        } catch {
          await scheduler.wait(1000);
          continue;
        }
        await scheduler.wait(1000);
        continue;
      }
      try {
        const probe = await this.shell(flavor, 'echo ready');
        if (probe.exitCode === 0 && probe.stdout.includes('ready')) {
          return;
        }
      } catch {
        await scheduler.wait(500);
        continue;
      }
      await scheduler.wait(500);
    }
    throw new Error(`${flavor} vm never accepted exec`);
  }

  private requireContainer(): Container {
    const container = this.ctx.container;
    if (!container) {
      throw new Error('container binding missing');
    }
    return container;
  }
}
