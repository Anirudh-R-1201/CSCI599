/**
 * k6 load test for Online Boutique — bursty east-west traffic measurement.
 *
 * Driven by environment variables set per-burst from the shell script:
 *   TOTAL_QPS    – total target iterations/s across all scenarios
 *   DURATION     – burst duration (e.g. "60s")
 *   W_HOME       – weight for home page (0.0–1.0)
 *   W_PRODUCT    – weight for product detail page
 *   W_CART       – weight for cart page
 *   W_CHECKOUT   – weight for checkout flow (stateful: add-to-cart + checkout)
 *   BURST_INDEX  – integer index of this burst (used in output filename)
 *   BURST_TYPE   – "spike" or "heavy_tail" (metadata only)
 *   FRONTEND_URL – base URL (default: http://frontend:80)
 *
 * Each k6 run writes a summary JSON to /tmp/k6-burst-{BURST_INDEX}.json.
 * The shell script kubectl-cp's this file to the data directory.
 *
 * Checkout is a 2-step VU flow (add item → submit checkout), so each VU
 * maintains its own session cookie jar. This exercises the full call chain:
 *   frontend → checkoutservice → {paymentservice, shippingservice,
 *              emailservice, currencyservice, cartservice, productcatalogservice}
 */

import http from 'k6/http';
import { check, sleep } from 'k6';
import { Trend, Counter, Rate } from 'k6/metrics';

// ── Configuration ────────────────────────────────────────────────────────────

const BASE = __ENV.FRONTEND_URL || 'http://frontend:80';

const TOTAL_QPS   = parseInt(__ENV.TOTAL_QPS   || '80');
const DURATION    = __ENV.DURATION             || '60s';
const BURST_INDEX = parseInt(__ENV.BURST_INDEX || '0');
const BURST_TYPE  = __ENV.BURST_TYPE           || 'unknown';

const W_HOME     = parseFloat(__ENV.W_HOME     || '0.35');
const W_PRODUCT  = parseFloat(__ENV.W_PRODUCT  || '0.40');
const W_CART     = parseFloat(__ENV.W_CART     || '0.25');
const W_CHECKOUT = parseFloat(__ENV.W_CHECKOUT || '0.00');
const W_TOTAL    = W_HOME + W_PRODUCT + W_CART + W_CHECKOUT;

// Per-scenario iteration rate (iterations/s = HTTP req/s for single-request
// scenarios; checkout does 2 HTTP reqs per iteration but that is intentional).
const QPS_HOME     = Math.max(1, Math.round(TOTAL_QPS * W_HOME     / W_TOTAL));
const QPS_PRODUCT  = Math.max(1, Math.round(TOTAL_QPS * W_PRODUCT  / W_TOTAL));
const QPS_CHECKOUT = Math.round(TOTAL_QPS * W_CHECKOUT / W_TOTAL);
const QPS_CART     = Math.max(1, TOTAL_QPS - QPS_HOME - QPS_PRODUCT - QPS_CHECKOUT);

// Online Boutique product IDs (from the seed catalog)
const PRODUCTS = [
  'OLJCESPC7Z', '66VCHSJNUP', '1YMWWN1N4O',
  'L9ECAV7KIM', '2ZYFJ3GM2N', '0PUK6V6EV0',
  'LS4PSXUNUM', 'HQTGWGPNH4', '6E92ZMYYFZ',
];

// ── Scenarios ────────────────────────────────────────────────────────────────

const checkoutScenario = QPS_CHECKOUT > 0 ? {
  checkout: {
    executor:        'constant-arrival-rate',
    rate:            QPS_CHECKOUT,
    timeUnit:        '1s',
    duration:        DURATION,
    preAllocatedVUs: Math.min(Math.ceil(QPS_CHECKOUT * 2), 60),
    maxVUs:          Math.min(QPS_CHECKOUT * 8, 200),
    exec:            'checkoutFlow',
  },
} : {};

export const options = {
  scenarios: {
    home: {
      executor:        'constant-arrival-rate',
      rate:            QPS_HOME,
      timeUnit:        '1s',
      duration:        DURATION,
      preAllocatedVUs: Math.min(Math.ceil(QPS_HOME * 0.3), 60),
      maxVUs:          Math.min(QPS_HOME * 4, 400),
      exec:            'browseHome',
    },
    product: {
      executor:        'constant-arrival-rate',
      rate:            QPS_PRODUCT,
      timeUnit:        '1s',
      duration:        DURATION,
      preAllocatedVUs: Math.min(Math.ceil(QPS_PRODUCT * 0.3), 60),
      maxVUs:          Math.min(QPS_PRODUCT * 4, 400),
      exec:            'browseProduct',
    },
    cart: {
      executor:        'constant-arrival-rate',
      rate:            QPS_CART,
      timeUnit:        '1s',
      duration:        DURATION,
      preAllocatedVUs: Math.min(Math.ceil(QPS_CART * 0.3), 30),
      maxVUs:          Math.min(QPS_CART * 4, 200),
      exec:            'viewCart',
    },
    ...checkoutScenario,
  },
  // Request percentiles to track (shown in summary and exported)
  summaryTrendStats: ['avg', 'p(50)', 'p(90)', 'p(95)', 'p(99)', 'p(99.9)', 'count'],
  // Don't spam logs with individual request failures
  noConnectionReuse: false,
  discardResponseBodies: true,
};

// ── Scenario functions ───────────────────────────────────────────────────────

export function browseHome() {
  const r = http.get(`${BASE}/`, { tags: { name: 'home' } });
  check(r, { 'home 2xx': (res) => res.status >= 200 && res.status < 400 });
}

export function browseProduct() {
  const id = PRODUCTS[(__VU + Math.floor(Math.random() * PRODUCTS.length)) % PRODUCTS.length];
  const r = http.get(`${BASE}/product/${id}`, { tags: { name: 'product' } });
  check(r, { 'product 2xx': (res) => res.status >= 200 && res.status < 400 });
}

export function viewCart() {
  const r = http.get(`${BASE}/cart`, { tags: { name: 'cart' } });
  check(r, { 'cart 2xx': (res) => res.status >= 200 && res.status < 400 });
}

export function checkoutFlow() {
  const id = PRODUCTS[__VU % PRODUCTS.length];

  // Step 1: add item to cart (each VU has its own cookie jar = its own session)
  http.post(`${BASE}/cart`, {
    product_id: id,
    quantity:   '1',
  }, { tags: { name: 'checkout' } });

  // Step 2: submit checkout — triggers the full 7-service east-west call chain
  const r = http.post(`${BASE}/cart/checkout`, {
    email:                        'test@example.com',
    street_address:               '123 Main St',
    zip_code:                     '10001',
    city:                         'New York',
    state:                        'NY',
    country:                      'US',
    credit_card_number:           '4432801561520454',
    credit_card_expiration_month: '1',
    credit_card_expiration_year:  '2030',
    credit_card_cvv:              '672',
  }, { tags: { name: 'checkout' } });

  check(r, { 'checkout 2xx': (res) => res.status >= 200 && res.status < 400 });
}

// ── Summary export ───────────────────────────────────────────────────────────
// Writes per-endpoint latency stats to a JSON file on the pod.
// The shell script kubectl-cp's this file after each burst run.

export function handleSummary(data) {
  const ms = (v) => typeof v === 'number' ? v : 0;

  // Extract per-name (endpoint tag) http_req_duration metrics
  const endpoints = {};
  for (const [key, metric] of Object.entries(data.metrics || {})) {
    if (!key.startsWith('http_req_duration')) continue;

    // Metric key format:  "http_req_duration{name:home}"  or  "http_req_duration"
    const nameMatch = key.match(/\{.*?name:([^,}]+)/);
    const ep = nameMatch ? nameMatch[1] : 'all';

    const v = metric.values || {};
    if (!endpoints[ep]) endpoints[ep] = {};

    // k6 reports latency in milliseconds; store in seconds for compat with graph script
    endpoints[ep] = {
      p50:        ms(v['p(50)'])   / 1000,
      p90:        ms(v['p(90)'])   / 1000,
      p95:        ms(v['p(95)'])   / 1000,
      p99:        ms(v['p(99)'])   / 1000,
      p999:       ms(v['p(99.9)']) / 1000,
      avg:        ms(v['avg'])     / 1000,
    };
  }

  // Add request counts and actual QPS from http_reqs metric
  for (const [key, metric] of Object.entries(data.metrics || {})) {
    if (!key.startsWith('http_reqs')) continue;
    const nameMatch = key.match(/\{.*?name:([^,}]+)/);
    const ep = nameMatch ? nameMatch[1] : 'all';
    if (!endpoints[ep]) continue;
    endpoints[ep].count      = (metric.values || {}).count || 0;
    endpoints[ep].actual_qps = (metric.values || {}).rate  || 0;
  }

  // Add error rate from http_req_failed metric (Rate: fraction of non-2xx responses)
  for (const [key, metric] of Object.entries(data.metrics || {})) {
    if (!key.startsWith('http_req_failed')) continue;
    const nameMatch = key.match(/\{.*?name:([^,}]+)/);
    const ep = nameMatch ? nameMatch[1] : 'all';
    if (!endpoints[ep]) continue;
    endpoints[ep].error_rate = (metric.values || {}).rate || 0;
  }

  const summary = {
    burst_index: BURST_INDEX,
    burst_type:  BURST_TYPE,
    total_qps:   TOTAL_QPS,
    duration_s:  parseFloat(DURATION),
    endpoints,
  };

  const outPath = `/tmp/k6-burst-${BURST_INDEX}.json`;
  return {
    [outPath]: JSON.stringify(summary, null, 2),
  };
}
