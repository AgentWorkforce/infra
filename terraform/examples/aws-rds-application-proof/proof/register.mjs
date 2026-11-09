/** Narrow alias only; original reviewed TypeScript and import.meta.url survive. */
import { registerHooks } from 'node:module';
export function install(sourceRoot) {
  const owner = new URL('src/shared/log.ts', sourceRoot).href;
  const scrub = new URL('packages/pipeline/src/lib/scrub.ts', sourceRoot).href;
  return registerHooks({ resolve(specifier, context, nextResolve) {
    if (specifier.startsWith('@rhc')) {
      if (specifier !== '@rhc/lib/scrub.ts' || context.parentURL !== owner) throw new Error('guest_alias_refused');
      return nextResolve(scrub, context);
    }
    return nextResolve(specifier, context);
  } });
}
