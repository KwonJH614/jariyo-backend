import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import execution from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const BASE_START_AT = requireOffsetTimestamp('BASE_START_AT');
const STRESSED_START_AT = requireOffsetTimestamp('STRESSED_START_AT');
const RESULT_DIR = (__ENV.RESULT_DIR || 'load-tests/issue-57/results/manual').replace(/\/$/, '');

if (BASE_START_AT === STRESSED_START_AT) {
	throw new Error('BASE_START_AT and STRESSED_START_AT must be different slots');
}

const STORE_ID = '00000000-0000-7000-8000-000000000001';
const SERVICE_ID = '00000000-0000-7000-8000-000000000401';
const STAFF_ID = '00000000-0000-7000-8000-000000000301';
const CUSTOMER_COUNT = 100;
const SIGN_UP_BATCH_SIZE = 10;
const BASE_MAX_DURATION = '30s';
const STRESSED_START_TIME = '35s';
const JSON_HEADERS = { 'Content-Type': 'application/json' };

const setupFailures = new Counter('setup_failures');
const reservationSuccess = new Counter('reservation_success');
const reservationConflict = new Counter('reservation_conflict');
const reservation5xx = new Rate('reservation_5xx');
const reservationUnexpected = new Rate('reservation_unexpected');
const baseReservationDuration = new Trend('base_reservation_duration');
const stressedReservationDuration = new Trend('stressed_reservation_duration');

export const options = {
	scenarios: {
		base: {
			executor: 'per-vu-iterations',
			exec: 'baseReservation',
			vus: 20,
			iterations: 1,
			maxDuration: BASE_MAX_DURATION,
		},
		stressed: {
			executor: 'per-vu-iterations',
			exec: 'stressedReservation',
			startTime: STRESSED_START_TIME,
			vus: 100,
			iterations: 1,
			maxDuration: '2m',
		},
	},
	thresholds: {
		setup_failures: ['count == 0'],
		'reservation_success{scenario:base,attempt:initial}': ['count == 1'],
		'reservation_conflict{scenario:base,attempt:initial}': ['count == 19'],
		'reservation_success{scenario:stressed,attempt:initial}': ['count == 1'],
		'reservation_conflict{scenario:stressed,attempt:initial}': ['count == 99'],
		'reservation_success{scenario:stressed,attempt:retry}': ['count == 0'],
		'reservation_conflict{scenario:stressed,attempt:retry}': ['count == 99'],
		base_reservation_duration: ['p(95) <= 1200', 'p(99) <= 2000'],
		stressed_reservation_duration: ['p(95) <= 2500', 'p(99) <= 4000'],
		'reservation_5xx{scenario:base}': ['rate <= 0.01'],
		'reservation_5xx{scenario:stressed}': ['rate <= 0.03'],
		'reservation_unexpected{scenario:base}': ['rate == 0'],
		'reservation_unexpected{scenario:stressed}': ['rate == 0'],
	},
};

export function setup() {
	const tokens = [];
	for (let start = 0; start < CUSTOMER_COUNT; start += SIGN_UP_BATCH_SIZE) {
		const requests = [];
		for (let offset = 0; offset < SIGN_UP_BATCH_SIZE; offset += 1) {
			const customerNumber = start + offset + 1;
			requests.push(['POST', `${BASE_URL}/api/v1/auth/sign-up`, JSON.stringify(signUpPayload(customerNumber)), {
				headers: JSON_HEADERS,
				tags: { phase: 'setup' },
			}]);
		}

		http.batch(requests).forEach((response) => {
			const token = signUpAccessToken(response);
			if (token === null) {
				setupFailures.add(1);
				return;
			}
			tokens.push(token);
		});
	}
	return { tokens };
}

export function baseReservation(data) {
	reserve(data.tokens, 'base', BASE_START_AT, false);
}

export function stressedReservation(data) {
	reserve(data.tokens, 'stressed', STRESSED_START_AT, true);
}

function reserve(tokens, scenario, startAt, retryNon201) {
	const token = tokens[execution.scenario.iterationInTest % CUSTOMER_COUNT];
	if (!token) {
		return;
	}

	const key = `issue57-${scenario}-${execution.scenario.iterationInTest}`;
	const body = JSON.stringify({
		storeId: STORE_ID,
		serviceId: SERVICE_ID,
		staffId: STAFF_ID,
		startAt,
		partySize: 1,
	});
	const initial = reservationRequest(token, key, body, scenario, 'initial');
	if (retryNon201 && initial.status !== 201) {
		sleep(1);
		reservationRequest(token, key, body, scenario, 'retry');
	}
}

function reservationRequest(token, key, body, scenario, attempt) {
	const tags = { scenario, attempt };
	const response = http.post(`${BASE_URL}/api/v1/reservations`, body, {
		headers: {
			...JSON_HEADERS,
			Authorization: `Bearer ${token}`,
			'Idempotency-Key': key,
		},
		tags,
		responseCallback: expectedReservationResponse,
	});
	const validConflict = isValidConflict(response);
	const semanticSuccess = response.status === 201;
	const semanticExpected = semanticSuccess || validConflict;

	if (semanticSuccess) {
		reservationSuccess.add(1, tags);
	}
	if (validConflict) {
		reservationConflict.add(1, tags);
	}
	reservation5xx.add(response.status >= 500 && response.status < 600 ? 1 : 0, { scenario });
	reservationUnexpected.add(semanticExpected ? 0 : 1, { scenario });
	if (scenario === 'base') {
		baseReservationDuration.add(response.timings.duration);
	} else {
		stressedReservationDuration.add(response.timings.duration);
	}
	check(response, {
		'reservation response is 201 or valid slot conflict': () => semanticExpected,
	});
	return response;
}

function expectedReservationResponse(response) {
	return response.status === 201 || isValidConflict(response);
}

function isValidConflict(response) {
	if (response.status !== 409) {
		return false;
	}
	try {
		return response.json('error.code') === 'RESERVATION_SLOT_ALREADY_TAKEN';
	} catch (_) {
		return false;
	}
}

function signUpPayload(customerNumber) {
	const suffix = String(customerNumber).padStart(3, '0');
	return {
		email: `issue57-${suffix}@example.com`,
		password: 'issue57-load-pass',
		displayName: `부하고객${suffix}`,
		phoneNumber: `010-57${suffix.slice(0, 2)}-${suffix.slice(1)}00`,
		agreements: { terms: true, privacy: true, marketing: false },
	};
}

function signUpAccessToken(response) {
	if (response.status !== 201) {
		return null;
	}
	try {
		const token = response.json('data.accessToken');
		return typeof token === 'string' && token.length > 0 ? token : null;
	} catch (_) {
		return null;
	}
}

function requireOffsetTimestamp(name) {
	const value = __ENV[name];
	if (!value || !/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2})$/.test(value)
		|| Number.isNaN(Date.parse(value))) {
		throw new Error(`${name} must be an ISO-8601 offset timestamp`);
	}
	return value;
}

export function handleSummary(data) {
	const markdown = [
		'# Issue #57 reservation conflict load test',
		'',
		'## Scenario counts',
		`- Base: success ${metricCount(data, 'reservation_success{scenario:base,attempt:initial}')}, conflict ${metricCount(data, 'reservation_conflict{scenario:base,attempt:initial}')}`,
		`- Stressed initial: success ${metricCount(data, 'reservation_success{scenario:stressed,attempt:initial}')}, conflict ${metricCount(data, 'reservation_conflict{scenario:stressed,attempt:initial}')}`,
		`- Stressed retry: success ${metricCount(data, 'reservation_success{scenario:stressed,attempt:retry}')}, conflict ${metricCount(data, 'reservation_conflict{scenario:stressed,attempt:retry}')}`,
		'',
		'## Latency and error rates',
		`- Base duration: p95 ${metricPercentile(data, 'base_reservation_duration', 'p(95)')} ms, p99 ${metricPercentile(data, 'base_reservation_duration', 'p(99)')} ms`,
		`- Stressed duration: p95 ${metricPercentile(data, 'stressed_reservation_duration', 'p(95)')} ms, p99 ${metricPercentile(data, 'stressed_reservation_duration', 'p(99)')} ms`,
		`- Base 5xx/unexpected: ${metricRate(data, 'reservation_5xx{scenario:base}')} / ${metricRate(data, 'reservation_unexpected{scenario:base}')}`,
		`- Stressed 5xx/unexpected: ${metricRate(data, 'reservation_5xx{scenario:stressed}')} / ${metricRate(data, 'reservation_unexpected{scenario:stressed}')}`,
		'',
		'## Threshold evidence',
		...thresholdEvidence(data),
		'',
	].join('\n');

	return {
		[`${RESULT_DIR}/summary.json`]: JSON.stringify(data, null, 2),
		[`${RESULT_DIR}/summary.md`]: markdown,
	};
}

function metricCount(data, name) {
	return metricValue(data, name, 'count');
}

function metricPercentile(data, name, percentile) {
	return metricValue(data, name, percentile);
}

function metricRate(data, name) {
	return metricValue(data, name, 'rate');
}

function metricValue(data, name, value) {
	const metric = data.metrics[name];
	return metric && metric.values[value] !== undefined ? metric.values[value] : 'n/a';
}

function thresholdEvidence(data) {
	const evidence = [];
	Object.keys(data.metrics).forEach((name) => {
		const thresholds = data.metrics[name].thresholds;
		if (!thresholds) {
			return;
		}
		Object.keys(thresholds).forEach((expression) => {
			const result = thresholds[expression];
			const status = result && result.ok === true ? 'PASS' : 'FAIL';
			evidence.push(`- ${name} ${expression}: ${status}`);
		});
	});
	return evidence;
}
