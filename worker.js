// The entry of the app on Cloudflare Workers: edge.com, the release of
// app.com (npm run build), with the runtime of the npm package beam.com.
// app.com has the native program too, which a Worker does not use, and
// with it the upload can be more than the limit of 64 MiB.
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
