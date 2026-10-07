import { DurableObject } from 'cloudflare:workers';

type BuildRequest = {
  sourceSha: string;
  script?: string;
  registryPassword: string;
  accountId: string;
};

type BuilderStatus = {
  running: boolean;
  exit: string;
  lastLog: string;
  memoryPeak: string;
  log: string;
  receipt: string;
};

const MANAGED_BUILDER_IMAGE = 'cloudflare/debian-trixie';
const BUILD_INACTIVITY_TIMEOUT_MS = 90 * 60 * 1000;
const NIX_STATIC_URL =
  'https://hydra.nixos.org/job/nix/master/buildStatic.nix-cli.x86_64-linux/latest/download-by-type/file/binary-dist';
const decoder = new TextDecoder();

const KEEPALIVE_INTERVAL_MS = 60 * 1000;

export class BuilderComputer extends DurableObject<Env> {
  constructor(ctx: DurableObjectState, env: Env) {
    super(ctx, env);
    if (ctx.container?.running) {
      void ctx.blockConcurrencyWhile(() => ctx.container!.setInactivityTimeout(BUILD_INACTIVITY_TIMEOUT_MS));
      this.recordExit();
    }
  }

  async alarm(): Promise<void> {
    if (this.ctx.container?.running) {
      const tail = await this.read(['tail', '-c', '6000', '/work-build.log']).catch(() => '');
      const memory = await this.read(['cat', '/sys/fs/cgroup/memory.peak']).catch(() => '');
      await this.ctx.storage.put('lastLog', tail);
      await this.ctx.storage.put('memoryPeak', memory.trim());
      await this.ctx.storage.setAlarm(Date.now() + KEEPALIVE_INTERVAL_MS);
    }
  }

  async startBuild(request: BuildRequest): Promise<{ started: boolean }> {
    const container = this.requireContainer();
    if (!container.running) {
      container.start({
        image: MANAGED_BUILDER_IMAGE,
        entrypoint: ['sleep', 'infinity'],
        enableInternet: true,
        instance: 'standard-4',
      });
    }
    await container.setInactivityTimeout(BUILD_INACTIVITY_TIMEOUT_MS);
    await this.ctx.storage.delete(['exit', 'lastLog', 'memoryPeak']);
    this.recordExit();
    await this.ctx.storage.setAlarm(Date.now() + KEEPALIVE_INTERVAL_MS);
    await this.waitForExec();
    const bootstrap = await this.fetchSource(request.sourceSha);
    await this.write('/work-bootstrap.sh', bootstrap);
    await container.exec(
      ['bash', '-c', 'nohup bash /work-bootstrap.sh > /work-build.log 2>&1 &'],
      {
        env: {
          SOURCE_SHA: request.sourceSha,
          REGISTRY_PASSWORD: request.registryPassword,
          ACCOUNT_ID: request.accountId,
          NIX_STATIC_URL,
          BUILDER_SCRIPT: request.script ?? 'builder.sh',
          PATH: '/usr/local/bin:/usr/bin:/bin',
        },
        stdout: 'ignore',
        stderr: 'ignore',
      },
    );
    return { started: true };
  }

  async status(): Promise<BuilderStatus> {
    const container = this.requireContainer();
    const exit = (await this.ctx.storage.get<string>('exit')) ?? '';
    const lastLog = (await this.ctx.storage.get<string>('lastLog')) ?? '';
    const memoryPeak = (await this.ctx.storage.get<string>('memoryPeak')) ?? '';
    if (!container.running) {
      return { running: false, exit, lastLog, memoryPeak, log: '', receipt: '' };
    }
    return {
      running: true,
      exit,
      lastLog,
      memoryPeak,
      log: await this.read(['tail', '-c', '6000', '/work-build.log']),
      receipt: await this.read(['cat', '/work/receipt.json']),
    };
  }

  async stop(): Promise<void> {
    const container = this.requireContainer();
    if (container.running) {
      await container.destroy('build finished');
    }
  }

  private recordExit(): void {
    const exit = this.requireContainer()
      .monitor()
      .then(
        () => this.ctx.storage.put('exit', `exited cleanly at ${new Date().toISOString()}`),
        (error: unknown) => this.ctx.storage.put('exit', `${String(error)} at ${new Date().toISOString()}`),
      );
    this.ctx.waitUntil(exit);
  }

  protected requireContainer(): Container {
    const container = this.ctx.container;
    if (!container) {
      throw new Error('container binding missing');
    }
    return container;
  }

  private async fetchSource(sourceSha: string): Promise<string> {
    const url = `https://raw.githubusercontent.com/acoyfellow/nix-cf-proof/${sourceSha}/scripts/bootstrap-builder.sh`;
    const response = await fetch(url);
    if (!response.ok) {
      throw new Error(`bootstrap fetch ${response.status}`);
    }
    return response.text();
  }

  private async waitForExec(): Promise<void> {
    for (let attempt = 0; attempt < 120; attempt++) {
      try {
        const process = await this.requireContainer().exec(['true']);
        if ((await process.output()).exitCode === 0) {
          return;
        }
      } catch {
        await scheduler.wait(500);
      }
    }
    throw new Error('builder never accepted exec');
  }

  private async write(path: string, contents: string): Promise<void> {
    const process = await this.requireContainer().exec(['tee', path], {
      stdin: new Blob([contents]).stream(),
      stdout: 'ignore',
    });
    const output = await process.output();
    if (output.exitCode !== 0) {
      throw new Error(`write ${path}: ${decoder.decode(output.stderr)}`);
    }
  }

  private async read(command: string[]): Promise<string> {
    const process = await this.requireContainer().exec(command);
    return decoder.decode((await process.output()).stdout);
  }
}
