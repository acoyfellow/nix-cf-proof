import { DurableObject } from 'cloudflare:workers';

type ContainerImageName = 'sandbox';

interface Env {
  SANDBOX: DurableObjectNamespace<SandboxComputer>;
  PROOF_TOKEN: string;
}

type CommandResult = {
  command: string[];
  exitCode: number;
  stdout: string;
  stderr: string;
};

const decoder = new TextDecoder();
const SANDBOX_IMAGE: ContainerImageName = 'sandbox';
const CONTAINER_READY_ATTEMPTS = 60;

export class SandboxComputer extends DurableObject<Env> {
  async probeSandbox(): Promise<Record<string, CommandResult>> {
    await this.ensureRunning(['/sandbox/bin/sleep', 'infinity']);
    return {
      receipt: await this.run(['/sandbox/bin/cat', '/proof/build-receipt.json']),
      identity: await this.run(['/sandbox/bin/git-identity']),
      forcePush: await this.run(['/sandbox/bin/force-push-probe']),
      uname: await this.run(['/sandbox/bin/uname', '-a']),
    };
  }

  async probeSystemd(): Promise<Record<string, CommandResult | string>> {
    const container = this.requireContainer();
    if (!container.running) {
      container.start({
        image: container.images[SANDBOX_IMAGE],
        entrypoint: ['/init'],
        enableInternet: false,
        instance: 'standard-1',
      });
    }
    const exit = container.monitor().then(
      () => 'exited:0',
      (error: unknown) => `exited:${String(error)}`,
    );
    const settled = await Promise.race([exit, scheduler.wait(20_000).then(() => 'alive-after-20s')]);
    if (settled !== 'alive-after-20s') {
      return { lifecycle: settled };
    }
    return {
      lifecycle: settled,
      pid1: await this.run(['/sandbox/bin/cat', '/proc/1/comm']),
      systemctl: await this.run(['/nixos-system/sw/bin/systemctl', 'is-system-running']),
      units: await this.run(['/nixos-system/sw/bin/systemctl', 'list-units', '--no-pager', '--state=failed']),
      journal: await this.run(['/nixos-system/sw/bin/journalctl', '-b', '--no-pager', '-n', '80']),
    };
  }

  async stop(): Promise<void> {
    const container = this.requireContainer();
    if (container.running) {
      await container.destroy('proof complete');
    }
  }

  private requireContainer(): Container {
    const container = this.ctx.container;
    if (!container) {
      throw new Error('container binding missing');
    }
    return container;
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

function authorized(request: Request, env: Env): boolean {
  return request.headers.get('authorization') === `Bearer ${env.PROOF_TOKEN}`;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
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
      if (pathname === '/stop' && request.method === 'POST') {
        await Promise.all([
          env.SANDBOX.getByName('sandbox').stop(),
          env.SANDBOX.getByName('systemd').stop(),
        ]);
        return Response.json({ stopped: true });
      }
    } catch (error) {
      return Response.json({ error: String(error) }, { status: 500 });
    }
    return new Response('not found', { status: 404 });
  },
};
