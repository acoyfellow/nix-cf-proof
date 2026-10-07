import { BuilderComputer } from './builder';

type ContainerImageName = 'sandbox';

type ProofEnv = Env & { PROOF_TOKEN: string; ACCOUNT_ID: string };

type CommandResult = {
  command: string[];
  exitCode: number;
  stdout: string;
  stderr: string;
};

const decoder = new TextDecoder();
const SANDBOX_IMAGE: ContainerImageName = 'sandbox';
const CONTAINER_READY_ATTEMPTS = 60;

export class SandboxComputer extends BuilderComputer {
  async probeSandbox(): Promise<Record<string, CommandResult>> {
    await this.ensureRunning(['/sandbox/bin/sleep', 'infinity']);
    return {
      receipt: await this.run(['/sandbox/bin/cat', '/proof/image.json']),
      identity: await this.run(['/sandbox/bin/git-identity']),
      forcePush: await this.run(['/sandbox/bin/force-push-probe']),
      uname: await this.run(['/sandbox/bin/uname', '-a']),
    };
  }

  async probeSystemd(): Promise<Record<string, CommandResult | string>> {
    const container = this.requireContainer();
    const steps: string[] = [];
    const capture = async (name: string, command: string[]): Promise<CommandResult | string> => {
      try {
        return await this.run(command);
      } catch (error) {
        steps.push(`${name}: ${String(error)}`);
        return `error: ${String(error)}`;
      }
    };
    try {
      if (container.running) {
        await container.destroy('restart for systemd probe');
      }
      container.start({
        image: container.images[SANDBOX_IMAGE],
        entrypoint: ['/boot-probe'],
        enableInternet: false,
        instance: 'standard-1',
      });
      steps.push('start accepted');
    } catch (error) {
      return { lifecycle: 'start-rejected', error: String(error), steps: steps.join('\n') };
    }
    const exit = container.monitor().then(
      () => 'exited:0',
      (error: unknown) => `exited:${String(error)}`,
    );
    const settled = await Promise.race([exit, scheduler.wait(45_000).then(() => 'alive-after-20s')]);
    steps.push(`lifecycle ${settled}`);
    if (settled !== 'alive-after-20s') {
      return { lifecycle: settled, steps: steps.join('\n') };
    }
    let console = '';
    try {
      const response = await container.getTcpPort(8080).fetch('http://container/');
      console = await response.text();
      steps.push(`console fetched ${console.length} bytes`);
    } catch (error) {
      steps.push(`console: ${String(error)}`);
    }
    return {
      lifecycle: settled,
      console,
      pid1: await capture('pid1', ['/sandbox/bin/cat', '/proc/1/comm']),
      pid1Cmdline: await capture('cmdline', ['/sandbox/bin/cat', '/proc/1/cmdline']),
      systemctl: await capture('systemctl', ['/nixos-system/sw/bin/systemctl', 'is-system-running']),
      units: await capture('units', ['/nixos-system/sw/bin/systemctl', 'list-units', '--no-pager', '--state=failed']),
      journal: await capture('journal', ['/nixos-system/sw/bin/journalctl', '-b', '--no-pager', '-n', '80']),
      steps: steps.join('\n'),
    };
  }

  private async ensureRunning(entrypoint: string[]): Promise<void> {
    const container = this.requireContainer();
    if (!container.running) {
      container.start({
        image: container.images[SANDBOX_IMAGE],
        entrypoint,
        enableInternet: false,
        instance: 'lite',
      });
    }
    for (let attempt = 0; attempt < CONTAINER_READY_ATTEMPTS; attempt++) {
      try {
        const ready = await this.run(['/sandbox/bin/true']);
        if (ready.exitCode === 0) {
          return;
        }
      } catch {
        await scheduler.wait(500);
      }
    }
    throw new Error('container never accepted exec');
  }

  private async run(command: string[]): Promise<CommandResult> {
    const process = await this.requireContainer().exec(command, {
      env: { HOME: '/tmp', PATH: '/sandbox/bin' },
    });
    const output = await process.output();
    return {
      command,
      exitCode: output.exitCode,
      stdout: decoder.decode(output.stdout),
      stderr: decoder.decode(output.stderr),
    };
  }
}

function authorized(request: Request, env: ProofEnv): boolean {
  return request.headers.get('authorization') === `Bearer ${env.PROOF_TOKEN}`;
}

export default {
  async fetch(request: Request, env: ProofEnv): Promise<Response> {
    if (!env.PROOF_TOKEN || !authorized(request, env)) {
      return new Response('unauthorized', { status: 401 });
    }
    const { pathname } = new URL(request.url);
    try {
      if (pathname === '/probe/sandbox') {
        return Response.json(await env.SANDBOX.getByName('sandbox').probeSandbox());
      }
      if (pathname === '/probe/systemd') {
        return Response.json(await env.SANDBOX.getByName('systemd').probeSystemd());
      }
      if (pathname === '/build/start' && request.method === 'POST') {
        const body = (await request.json()) as { sourceSha: string; registryPassword: string; script?: string };
        return Response.json(
          await env.SANDBOX.getByName('builder').startBuild({ ...body, accountId: env.ACCOUNT_ID }),
        );
      }
      if (pathname === '/build/status') {
        return Response.json(await env.SANDBOX.getByName('builder').status());
      }
      if (pathname === '/stop' && request.method === 'POST') {
        await Promise.all([
          env.SANDBOX.getByName('sandbox').stop(),
          env.SANDBOX.getByName('systemd').stop(),
          env.SANDBOX.getByName('builder').stop(),
        ]);
        return Response.json({ stopped: true });
      }
    } catch (error) {
      return Response.json({ error: String(error) }, { status: 500 });
    }
    return new Response('not found', { status: 404 });
  },
};
