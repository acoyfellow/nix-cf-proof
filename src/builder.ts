import { DurableObject } from 'cloudflare:workers';

type BuildRequest = {
  sourceSha: string;
  registryPassword: string;
  accountId: string;
};

type BuilderStatus = {
  running: boolean;
  log: string;
  receipt: string;
};

const MANAGED_BUILDER_IMAGE = 'cloudflare/debian-trixie';
const BUILD_INACTIVITY_TIMEOUT_MS = 90 * 60 * 1000;
const NIX_STATIC_URL =
  'https://hydra.nixos.org/job/nix/master/buildStatic.nix-cli.x86_64-linux/latest/download-by-type/file/binary-dist';
const decoder = new TextDecoder();

export class BuilderComputer extends DurableObject<Env> {
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
    if (!container.running) {
      return { running: false, log: '', receipt: '' };
    }
    return {
      running: true,
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
