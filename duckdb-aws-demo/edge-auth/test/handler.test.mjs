import { test } from 'node:test';
import assert from 'node:assert/strict';
import { SecretsManagerClient } from '@aws-sdk/client-secrets-manager';

process.env.AWS_LAMBDA_FUNCTION_NAME = 'us-east-1.duckdemo-edge-auth';

const CONFIG = {
  region: 'eu-west-1',
  userPoolId: 'eu-west-1_TestPool1',
  userPoolAppId: 'testclientid1234567890abcd',
  userPoolAppSecret: 'testsecret',
  userPoolDomain: 'duckdemo-test.auth.eu-west-1.amazoncognito.com',
  nonceSigningSecret: 'x'.repeat(32),
};

let mode = 'fail';
let requestedSecretId;
SecretsManagerClient.prototype.send = async function send(cmd) {
  requestedSecretId = cmd.input.SecretId;
  if (mode === 'fail') throw new Error('AccessDenied');
  return { SecretString: JSON.stringify(CONFIG) };
};

const { handler, _internal } = await import('../src/index.mjs');

function event(uri, { querystring = '', method = 'GET', cookie } = {}) {
  const headers = { host: [{ key: 'Host', value: 'd111111abcdef8.cloudfront.net' }] };
  if (cookie) headers.cookie = [{ key: 'Cookie', value: cookie }];
  return { Records: [{ cf: { request: { uri, querystring, method, headers, clientIp: '203.0.113.10' } } }] };
}

test('secret id is derived from the function name, including replicas', () => {
  assert.equal(_internal.secretIdFor('duckdemo-edge-auth'), 'duckdemo-edge-auth/config');
  assert.equal(_internal.secretIdFor('us-east-1.duckdemo-edge-auth'), 'duckdemo-edge-auth/config');
});

test('fails closed with 503 when the configuration cannot be loaded', async () => {
  mode = 'fail';
  const res = await handler(event('/'));
  assert.equal(res.status, '503');
  assert.equal(requestedSecretId, 'duckdemo-edge-auth/config');
});

test('anonymous request is redirected to the Cognito login with a signed CSRF nonce', async () => {
  mode = 'ok';
  const res = await handler(event('/notebooks'));
  assert.equal(res.status, '302');
  const location = new URL(res.headers.location[0].value);
  assert.equal(location.host, CONFIG.userPoolDomain);
  assert.equal(location.pathname, '/authorize');
  assert.equal(location.searchParams.get('redirect_uri'), 'https://d111111abcdef8.cloudfront.net/_auth/callback');
  assert.ok(location.searchParams.get('state'), 'state expected');
  const cookies = res.headers['set-cookie'].map((c) => c.value);
  assert.ok(cookies.some((c) => /\.nonce=/.test(c)), 'nonce cookie expected');
  assert.ok(cookies.some((c) => /\.nonceHmac=/.test(c)), 'nonce HMAC cookie expected');
  assert.ok(cookies.every((c) => /Secure/.test(c) && /HttpOnly/.test(c)), 'cookies must be Secure and HttpOnly');
});

test('callback without valid CSRF cookies is rejected and never exchanges the code', async () => {
  mode = 'ok';
  const res = await handler(event('/_auth/callback', { querystring: 'code=abc&state=xyz' }));
  assert.equal(res.status, '401');
});

test('anonymous POST to the query API never reaches the origin', async () => {
  mode = 'ok';
  const res = await handler(event('/ddb/run', { method: 'POST' }));
  assert.notEqual(res.uri, '/ddb/run', 'request object must not be returned');
  assert.equal(res.status, '302');
});

test('forged token cookie is rejected', async () => {
  mode = 'ok';
  const forged = `CognitoIdentityServiceProvider.${CONFIG.userPoolAppId}.admin.idToken=eyJhbGciOiJub25lIn0.eyJzdWIiOiJ4In0.`;
  const res = await handler(event('/', { cookie: forged }));
  assert.ok(res.status === '302' || res.status === '401', `unexpected status ${res.status}`);
  assert.equal(res.uri, undefined);
});

test('an OAuth code outside the callback path is not exchanged', async () => {
  mode = 'ok';
  const res = await handler(event('/', { querystring: 'code=attacker-code&x=1' }));
  assert.equal(res.status, '302');
  assert.equal(new URL(res.headers.location[0].value).host, CONFIG.userPoolDomain);
});
