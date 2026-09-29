import type { D1Migration } from "cloudflare:test";
import type * as Main from "../src/index";

type ServiceEnv = Main.Env;

declare global {
  namespace Cloudflare {
    interface GlobalProps {
      mainModule: typeof Main;
    }
    interface Env extends ServiceEnv {
      TEST_MIGRATIONS: D1Migration[];
      TEST_PUBLIC_KEY: string;
    }
  }
}
