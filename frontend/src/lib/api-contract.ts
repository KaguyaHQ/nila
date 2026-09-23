import type { operations } from "./generated/workspace";

export type ApiBody<K extends keyof operations> = operations[K] extends {
  requestBody: { content: { "application/json": infer Body } };
} ? Body : never;

export type ApiResult<K extends keyof operations> = operations[K] extends {
  responses: infer Responses;
} ? {
  [S in keyof Responses]: S extends 200 | 202
    ? Responses[S] extends { content: { "application/json": infer Body } } ? Body : never
    : never;
}[keyof Responses] : never;
