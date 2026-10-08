// The entry of the app on Cloudflare Workers: edge.com, the release of the
// app for the WebAssembly runtime (npm run build, scripts/edge-com.sh), with
// the runtime of the npm package beam.com.
import app from './edge.com' with { type: 'bytes' };
import { serve } from 'beam.com';

// One Durable Object (the binding BEAM of wrangler.jsonc) runs one VM for
// all the requests: the pages, and the LiveView of each open page.
export { Beam } from 'beam.com';

const beam = serve(app);

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
};
