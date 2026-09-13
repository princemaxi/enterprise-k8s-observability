// k6 load test for the Order API -- drives the ~1,000 req/sec assumption
// used in docs/capacity-planning.md so the sizing is validated against
// real load, not just a spreadsheet.
//
// Run:  k6 run --vus 200 --duration 5m scripts/perf-test.js
// Or ramp gradually to find the actual breaking point:
//   k6 run scripts/perf-test.js   (uses the stages defined below)

import http from "k6/http";
import { check, sleep } from "k6";

const BASE_URL = __ENV.BASE_URL || "https://order-api.logging.qyonlimited.com";

export const options = {
  stages: [
    { duration: "1m", target: 50 },
    { duration: "2m", target: 200 }, // ~1000 req/sec at ~5 req/sec/VU
    { duration: "5m", target: 200 }, // sustain -- this is the number that matters
    { duration: "1m", target: 0 },
  ],
  thresholds: {
    http_req_duration: ["p(95)<500"], // matches the duration_ms field indexed by the app
    http_req_failed: ["rate<0.05"],
  },
};

const USERS = ["alice", "bob", "carla", "dara", ""]; // "" deliberately triggers login failures

export default function () {
  const user = USERS[Math.floor(Math.random() * USERS.length)];

  // GET /products
  let res = http.get(`${BASE_URL}/products`);
  check(res, { "products 200": (r) => r.status === 200 });

  // POST /login
  res = http.post(
    `${BASE_URL}/login`,
    JSON.stringify({ username: user }),
    { headers: { "Content-Type": "application/json" } }
  );
  check(res, { "login handled": (r) => [200, 401].includes(r.status) });

  // POST /checkout
  res = http.post(
    `${BASE_URL}/checkout`,
    JSON.stringify({ product_id: Math.ceil(Math.random() * 4), user }),
    { headers: { "Content-Type": "application/json" } }
  );

  // POST /payment
  res = http.post(
    `${BASE_URL}/payment`,
    JSON.stringify({ amount: Math.random() * 100, user }),
    { headers: { "Content-Type": "application/json" } }
  );

  // POST /orders
  res = http.post(
    `${BASE_URL}/orders`,
    JSON.stringify({ user, item: "book" }),
    { headers: { "Content-Type": "application/json" } }
  );
  check(res, { "order handled": (r) => [201, 500].includes(r.status) });

  sleep(0.2);
}

// After a run: capture Elasticsearch indexing throughput alongside k6's
// own output for the "Performance Testing" deliverable:
//   watch -n5 'curl_es "$ES_URL/app-logs-*/_stats/indexing?pretty" | grep index_total'
