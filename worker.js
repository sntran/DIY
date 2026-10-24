// The entry of the app on Cloudflare Workers: edge.com, the release of the
// app for the WebAssembly runtime (npm run build, scripts/edge-com.sh), with
// the runtime of the npm package beam.com.
import app from './edge.com' with { type: 'bytes' };
import { serve } from 'beam.com';
// The NIF libraries in WebAssembly of edge.com (the NIF of DIY.Picture):
// scripts/edge-com.sh writes nifs.js with "beam.com --nif-modules".
import nifs from './nifs.js';

// One Durable Object (the binding BEAM of wrangler.jsonc) runs one VM for
// all the requests: the pages, and the LiveView of each open page.
export { Beam } from 'beam.com';

const beam = serve(app, { nifs });

export default {
  fetch(request, env, ctx) {
    return beam.fetch(request, env, ctx);
  },
};
