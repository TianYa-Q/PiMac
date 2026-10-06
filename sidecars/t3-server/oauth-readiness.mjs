import * as Effect from 'effect/Effect';
import { HttpServerRequest } from 'effect/http';
import { loopbackOAuthCallbackAllowed } from './oauth-policy.mjs';

// The separate OAuth listener does not have the main server's startup service.
// Do not resolve that service for its narrowly validated loopback callback.
export function oauthAwareCommandReadiness(httpEffect, awaitReady) {
  return Effect.flatMap(HttpServerRequest.HttpServerRequest, request =>
    loopbackOAuthCallbackAllowed(request)
      ? httpEffect
      : awaitReady.pipe(Effect.andThen(httpEffect)));
}
