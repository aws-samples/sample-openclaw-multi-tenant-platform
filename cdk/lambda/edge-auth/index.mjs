import { createRemoteJWKSet, jwtVerify } from 'jose';

const CONFIG = {
  COGNITO_REGION: 'us-west-2',
  COGNITO_USER_POOL_ID: 'us-west-2_yRqDzKF0t',
  COOKIE_NAME: 'claw_id_token',
  IDENTITY_HEADER: 'x-amzn-oidc-identity',
};

const ISSUER = `https://cognito-idp.${CONFIG.COGNITO_REGION}.amazonaws.com/${CONFIG.COGNITO_USER_POOL_ID}`;
const JWKS = createRemoteJWKSet(new URL(`${ISSUER}/.well-known/jwks.json`));

const UNAUTHORIZED = {
  status: '401',
  statusDescription: 'Unauthorized',
  headers: { 'content-type': [{ value: 'application/json' }] },
  body: JSON.stringify({ error: 'unauthorized', redirect: '/' }),
};

function parseCookie(headers) {
  const cookieHeader = headers.cookie;
  if (!cookieHeader) return null;
  for (const entry of cookieHeader) {
    const match = entry.value.split(';')
      .map(c => c.trim().split('='))
      .find(([k]) => k === CONFIG.COOKIE_NAME);
    if (match) return match[1];
  }
  return null;
}

export async function handler(event) {
  const request = event.Records[0].cf.request;
  const token = parseCookie(request.headers);
  if (!token) return UNAUTHORIZED;

  try {
    const { payload } = await jwtVerify(token, JWKS, {
      issuer: ISSUER,
    });
    if (payload.token_use !== 'id') return UNAUTHORIZED;

    // Strip existing header (anti-spoofing) then inject verified identity
    delete request.headers[CONFIG.IDENTITY_HEADER];
    request.headers[CONFIG.IDENTITY_HEADER] = [{ value: payload.email }];
    return request;
  } catch {
    return UNAUTHORIZED;
  }
}
