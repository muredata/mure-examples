// Lambda@Edge viewer-request handler: every request to the distribution must carry a
// valid Cognito ID token (cookie), otherwise the viewer is sent to the Cognito login page.
//
// Lambda@Edge can't use environment variables, so the configuration (user pool, app
// client and its secret, Cognito domain, CSRF signing secret) is read from AWS Secrets Manager in
// us-east-1 and cached. The secret name is the only value baked into the bundle, and it
// is derived from the function name, which Terraform controls.
//
// Fail closed: if the configuration can't be loaded, the request is rejected with 503.

import { SecretsManagerClient, GetSecretValueCommand } from '@aws-sdk/client-secrets-manager';
import { Authenticator } from 'cognito-at-edge';

const CALLBACK_PATH = '/_auth/callback';
const SIGN_OUT_PATH = '/_auth/signout';
const CONFIG_TTL_MS = 5 * 60 * 1000;

const secrets = new SecretsManagerClient({ region: 'us-east-1' });
let cached = { authenticator: null, loadedAt: 0 };

// Function names look like "<prefix>-edge-auth" (replicas: "us-east-1.<prefix>-edge-auth").
function secretIdFor(functionName) {
  const base = functionName.replace(/^us-east-1\./, '');
  return `${base}/config`;
}

async function getAuthenticator() {
  const now = Date.now();
  if (cached.authenticator && now - cached.loadedAt < CONFIG_TTL_MS) {
    return cached.authenticator;
  }
  const out = await secrets.send(
    new GetSecretValueCommand({ SecretId: secretIdFor(process.env.AWS_LAMBDA_FUNCTION_NAME) }),
  );
  const cfg = JSON.parse(out.SecretString);
  for (const key of ['region', 'userPoolId', 'userPoolAppId', 'userPoolAppSecret', 'userPoolDomain', 'nonceSigningSecret']) {
    if (!cfg[key]) throw new Error(`edge auth config is missing ${key}`);
  }
  const authenticator = new Authenticator({
    region: cfg.region,
    userPoolId: cfg.userPoolId,
    userPoolAppId: cfg.userPoolAppId,
    userPoolAppSecret: cfg.userPoolAppSecret,
    userPoolDomain: cfg.userPoolDomain,
    parseAuthPath: CALLBACK_PATH,
    cookiePath: '/',
    httpOnly: true,
    sameSite: 'Lax',
    cookieExpirationDays: 1,
    csrfProtection: { nonceSigningSecret: cfg.nonceSigningSecret },
    logoutConfiguration: { logoutUri: SIGN_OUT_PATH, logoutRedirectUri: '/' },
    logLevel: 'warn',
  });
  cached = { authenticator, loadedAt: now };
  return authenticator;
}

function plainResponse(status, description, body) {
  return {
    status: String(status),
    statusDescription: description,
    headers: {
      'content-type': [{ key: 'Content-Type', value: 'text/plain; charset=utf-8' }],
      'cache-control': [{ key: 'Cache-Control', value: 'no-store' }],
    },
    body,
  };
}

export const handler = async (event) => {
  const request = event.Records[0].cf.request;
  let authenticator;
  try {
    authenticator = await getAuthenticator();
  } catch (err) {
    console.error('edge auth: configuration unavailable, rejecting request', err);
    return plainResponse(503, 'Service Unavailable', 'Authentication is not available.');
  }

  try {
    if (request.uri === CALLBACK_PATH) {
      // Code exchange after validating the signed nonce cookies against `state` (CSRF).
      const res = await authenticator.handleParseAuth(event);
      if (res.status !== '302') {
        return plainResponse(401, 'Unauthorized', 'Sign-in failed. Reload the page to try again.');
      }
      // In CSRF mode the library stores the callback URL itself in `state`, which yields a
      // malformed Location. The UI is a single-page app, so always land on its root.
      const host = request.headers.host[0].value;
      res.headers.location = [{ key: 'Location', value: `https://${host}/` }];
      return res;
    }
    // An OAuth "code" is only meaningful on the callback path; drop it elsewhere so the
    // generic handler can't be used for an unvalidated code exchange.
    if (request.querystring) {
      const params = new URLSearchParams(request.querystring);
      if (params.has('code')) {
        params.delete('code');
        request.querystring = params.toString();
      }
    }
    return await authenticator.handle(event);
  } catch (err) {
    console.error('edge auth: rejecting request', err?.message);
    return plainResponse(401, 'Unauthorized', 'Unauthorized.');
  }
};

export const _internal = { secretIdFor };
