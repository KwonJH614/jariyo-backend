import http from 'k6/http';
import { check, sleep } from 'k6';
import { Counter, Rate, Trend } from 'k6/metrics';
import execution from 'k6/execution';

const BASE_URL = __ENV.BASE_URL || 'http://localhost:8080';
const ADMIN_TOKEN = __ENV.ADMIN_TOKEN;
const RESULT_DIR = (__ENV.RESULT_DIR || 'load-tests/issue-56/results/manual').replace(/\/$/, '');
const STORE_ID = '00000000-0000-7000-8000-000000000001';
const SERVICE_ID = '00000000-0000-7000-8000-000000000401';
const CUSTOMER_COUNT = 180;
const BASE_USERS = 40;
const JSON_HEADERS = { 'Content-Type': 'application/json' };
const expectedOk = http.expectedStatuses(200);
const expectedCreated = http.expectedStatuses(201);

const setupFailures = new Counter('setup_failures');
const walkInPollStarted = new Counter('walk_in_poll_started');
const basePollDuration = new Trend('base_poll_duration');
const stressedPollDuration = new Trend('stressed_poll_duration');
const poll5xx = new Rate('poll_5xx');
const pollUnexpected = new Rate('poll_unexpected');
const operatorFailures = new Counter('operator_failures');
const reflectionFailures = new Counter('reflection_failures');
const stateReflectionDuration = new Trend('state_reflection_duration');

let baseEntryIndex = null;
let stressedEntryIndex = null;
let baseNextPollAt = null;
let stressedNextPollAt = null;

export const options = {
	setupTimeout: '10m',
	summaryTrendStats: ['avg', 'p(95)', 'p(99)', 'max'],
	scenarios: {
		base: {
			executor: 'constant-vus',
			exec: 'basePolling',
			vus: BASE_USERS,
			duration: '30s',
			gracefulStop: '5s',
		},
		base_operator: {
			executor: 'shared-iterations',
			exec: 'baseOperator',
			vus: 1,
			iterations: 1,
			startTime: '10s',
			maxDuration: '20s',
		},
		stressed: {
			executor: 'constant-vus',
			exec: 'stressedPolling',
			startTime: '35s',
			vus: CUSTOMER_COUNT,
			duration: '30s',
			gracefulStop: '5s',
		},
		stressed_operator: {
			executor: 'shared-iterations',
			exec: 'stressedOperator',
			vus: 1,
			iterations: 1,
			startTime: '45s',
			maxDuration: '20s',
		},
	},
	thresholds: {
		setup_failures: ['count == 0'],
		base_poll_duration: ['p(95) <= 500', 'p(99) <= 900'],
		stressed_poll_duration: ['p(95) <= 1200', 'p(99) <= 2000'],
		'poll_5xx{scenario:base}': ['rate <= 0.01'],
		'poll_5xx{scenario:stressed}': ['rate <= 0.03'],
		'poll_unexpected{scenario:base}': ['rate == 0'],
		'poll_unexpected{scenario:stressed}': ['rate == 0'],
		operator_failures: ['count == 0'],
		reflection_failures: ['count == 0'],
	},
};

export function setup() {
	if (!ADMIN_TOKEN) {
		throw new Error('ADMIN_TOKEN is required');
	}

	const customers = [];
	for (let start = 0; start < CUSTOMER_COUNT; start += 10) {
		const requests = [];
		for (let offset = 0; offset < 10; offset += 1) {
			const customerNumber = start + offset + 1;
			requests.push(['POST', `${BASE_URL}/api/v1/auth/sign-up`, JSON.stringify(signUpPayload(customerNumber)), {
				headers: JSON_HEADERS,
				tags: { phase: 'setup', operation: 'signup' },
				responseCallback: expectedCreated,
			}]);
		}
		const responses = http.batch(requests);
		responses.forEach((response, offset) => {
			const customer = signUpCustomer(response, start + offset + 1);
			if (customer === null) {
				setupFailures.add(1);
			} else {
				customers.push(customer);
			}
		});
	}

	if (customers.length !== CUSTOMER_COUNT) {
		throw new Error(`expected ${CUSTOMER_COUNT} customer tokens, got ${customers.length}`);
	}

	const entries = [];
	for (let start = 0; start < CUSTOMER_COUNT; start += 10) {
		const requests = customers.slice(start, start + 10).map((customer) => [
			'POST',
			`${BASE_URL}/api/v1/walk-ins`,
			JSON.stringify({ storeId: STORE_ID, serviceId: SERVICE_ID, preferredStaffId: null, partySize: 1 }),
			{
				headers: {
					...JSON_HEADERS,
					Authorization: `Bearer ${customer.token}`,
					'Idempotency-Key': `issue56-register-${customer.number}`,
				},
				tags: { phase: 'setup', operation: 'register' },
				responseCallback: expectedOk,
			},
		]);
		const responses = http.batch(requests);
		responses.forEach((response, offset) => {
			const customer = customers[start + offset];
			const entry = registeredEntry(response, customer);
			if (entry === null) {
				setupFailures.add(1);
			} else {
				entries.push(entry);
			}
		});
	}

	if (entries.length !== CUSTOMER_COUNT) {
		throw new Error(`expected ${CUSTOMER_COUNT} walk-ins, got ${entries.length}`);
	}
	entries.sort((left, right) => left.queueNumber - right.queueNumber);
	return {
		entries,
		baseCheckedIn: findByCustomerNumber(entries, 1),
		baseRestored: findByCustomerNumber(entries, 2),
		stressedCheckedIn: findByCustomerNumber(entries, 3),
		stressedRestored: findByCustomerNumber(entries, 4),
		observer: entries[entries.length - 1],
	};
}

export function basePolling(data) {
	if (baseEntryIndex === null) {
		baseEntryIndex = execution.scenario.iterationInTest % BASE_USERS;
		sleep(Math.floor(baseEntryIndex / 8));
		baseNextPollAt = Date.now();
	}
	poll(data.entries[baseEntryIndex], 'base');
	baseNextPollAt += 5000;
	sleep(Math.max(0, baseNextPollAt - Date.now()) / 1000);
}

export function stressedPolling(data) {
	if (stressedEntryIndex === null) {
		stressedEntryIndex = execution.scenario.iterationInTest % CUSTOMER_COUNT;
		sleep(Math.floor(stressedEntryIndex / 90));
		stressedNextPollAt = Date.now();
	}
	poll(data.entries[stressedEntryIndex], 'stressed');
	stressedNextPollAt += 2000;
	sleep(Math.max(0, stressedNextPollAt - Date.now()) / 1000);
}

export function baseOperator(data) {
	mutateCheckedIn(data.baseCheckedIn, data.observer, 178, 'base');
	mutateSkippedAndRestored(data.baseRestored, 'base');
}

export function stressedOperator(data) {
	mutateCheckedIn(data.stressedCheckedIn, data.observer, 177, 'stressed');
	mutateSkippedAndRestored(data.stressedRestored, 'stressed');
}

function poll(entry, scenario) {
	const tags = { scenario };
	walkInPollStarted.add(1, tags);
	const response = http.get(`${BASE_URL}/api/v1/walk-ins/${entry.id}`, {
		headers: { Authorization: `Bearer ${entry.token}` },
		tags,
		responseCallback: expectedOk,
	});
	const valid = validDetail(response, entry);
	poll5xx.add(response.status >= 500 && response.status < 600 ? 1 : 0, tags);
	pollUnexpected.add(valid ? 0 : 1, tags);
	if (scenario === 'base') {
		basePollDuration.add(response.timings.duration);
	} else {
		stressedPollDuration.add(response.timings.duration);
	}
	check(response, { 'walk-in polling response is current and valid': () => valid });
}

function mutateCheckedIn(target, observer, expectedWaitingAhead, phase) {
	adminPost(target.id, 'call', { responseTimeoutMinutes: 3 }, `${phase}-call`);
	assertReflected(target, 'CALLED', `${phase}-called`);
	adminPost(target.id, 'check-in', null, `${phase}-check-in`);
	assertReflected(target, 'CHECKED_IN', `${phase}-checked-in`);
	assertObserver(observer, expectedWaitingAhead, `${phase}-observer-after-check-in`);
}

function mutateSkippedAndRestored(target, phase) {
	adminPost(target.id, 'call', { responseTimeoutMinutes: 3 }, `${phase}-skip-call`);
	assertReflected(target, 'CALLED', `${phase}-skip-called`);
	adminPost(target.id, 'skip', { reason: '부하 테스트 보류' }, `${phase}-skip`);
	assertReflected(target, 'SKIPPED', `${phase}-skipped`);
	adminPost(target.id, 'restore', null, `${phase}-restore`);
	assertReflected(target, 'WAITING', `${phase}-restored`);
}

function adminPost(walkInId, operation, body, key) {
	const response = http.post(`${BASE_URL}/api/v1/admin/stores/${STORE_ID}/walk-ins/${walkInId}/${operation}`,
		body === null ? null : JSON.stringify(body), {
			headers: {
				...JSON_HEADERS,
				Authorization: `Bearer ${ADMIN_TOKEN}`,
				'Idempotency-Key': `issue56-${key}`,
			},
			tags: { scenario: 'operator', phase: key },
			responseCallback: expectedOk,
		});
	const valid = response.status === 200 && response.json('data.id') === walkInId;
	if (!valid) {
		operatorFailures.add(1, { phase: key });
	}
	check(response, { [`${key} operator mutation succeeds`]: () => valid });
}

function assertReflected(entry, expectedStatus, phase) {
	const response = http.get(`${BASE_URL}/api/v1/walk-ins/${entry.id}`, {
		headers: { Authorization: `Bearer ${entry.token}` },
		tags: { scenario: 'reflection', phase },
		responseCallback: expectedOk,
	});
	stateReflectionDuration.add(response.timings.duration, { phase });
	const valid = response.status === 200 && response.json('data.id') === entry.id
		&& response.json('data.status') === expectedStatus;
	if (!valid) {
		reflectionFailures.add(1, { phase });
	}
	check(response, { [`${phase} is immediately visible`]: () => valid });
}

function assertObserver(observer, expectedWaitingAhead, phase) {
	const response = http.get(`${BASE_URL}/api/v1/walk-ins/${observer.id}`, {
		headers: { Authorization: `Bearer ${observer.token}` },
		tags: { scenario: 'reflection', phase },
		responseCallback: expectedOk,
	});
	stateReflectionDuration.add(response.timings.duration, { phase });
	const valid = response.status === 200 && response.json('data.waitingAhead') === expectedWaitingAhead;
	if (!valid) {
		reflectionFailures.add(1, { phase });
	}
	check(response, { [`${phase} waitingAhead is immediately visible`]: () => valid });
}

function validDetail(response, entry) {
	if (response.status !== 200) {
		return false;
	}
	try {
		const data = response.json('data');
		return data.id === entry.id
			&& data.queueNumber === entry.queueNumber
			&& Number.isInteger(data.waitingAhead)
			&& data.waitingAhead >= 0
			&& data.estimatedWaitMinutes === entry.estimatedWaitMinutes
			&& ['WAITING', 'CALLED', 'CHECKED_IN', 'SKIPPED'].includes(data.status);
	} catch (_) {
		return false;
	}
}

function signUpPayload(customerNumber) {
	const suffix = String(customerNumber).padStart(3, '0');
	return {
		email: `issue56-${suffix}@example.com`,
		password: 'issue56-customer-load-pass',
		displayName: targetDisplayName(customerNumber),
		phoneNumber: `01056${suffix}000`,
		agreements: { terms: true, privacy: true, marketing: false },
	};
}

function targetDisplayName(customerNumber) {
	if (customerNumber === 1) return 'issue56-base-checked-in';
	if (customerNumber === 2) return 'issue56-base-restored';
	if (customerNumber === 3) return 'issue56-stressed-checked-in';
	if (customerNumber === 4) return 'issue56-stressed-restored';
	return `부하고객${String(customerNumber).padStart(3, '0')}`;
}

function signUpCustomer(response, customerNumber) {
	if (response.status !== 201) {
		return null;
	}
	try {
		const token = response.json('data.accessToken');
		return typeof token === 'string' && token.length > 0 ? { number: customerNumber, token } : null;
	} catch (_) {
		return null;
	}
}

function registeredEntry(response, customer) {
	if (response.status !== 200) {
		return null;
	}
	try {
		const data = response.json('data');
		if (typeof data.id !== 'string' || !Number.isInteger(data.queueNumber)) {
			return null;
		}
		return {
			id: data.id,
			queueNumber: data.queueNumber,
			estimatedWaitMinutes: data.estimatedWaitMinutes,
			number: customer.number,
			token: customer.token,
		};
	} catch (_) {
		return null;
	}
}

function findByCustomerNumber(entries, number) {
	const match = entries.find((entry) => entry.number === number);
	if (!match) {
		throw new Error(`walk-in target customer ${number} is missing`);
	}
	return match;
}

export function handleSummary(data) {
	const markdown = [
		'# Issue #56 walk-in polling load test',
		'',
		'## Latency and error rates',
		`- Base duration: p95 ${metricValue(data, 'base_poll_duration', 'p(95)')} ms, p99 ${metricValue(data, 'base_poll_duration', 'p(99)')} ms`,
		`- Stressed duration: p95 ${metricValue(data, 'stressed_poll_duration', 'p(95)')} ms, p99 ${metricValue(data, 'stressed_poll_duration', 'p(99)')} ms`,
		`- Base 5xx/unexpected: ${metricValue(data, 'poll_5xx{scenario:base}', 'rate')} / ${metricValue(data, 'poll_unexpected{scenario:base}', 'rate')}`,
		`- Stressed 5xx/unexpected: ${metricValue(data, 'poll_5xx{scenario:stressed}', 'rate')} / ${metricValue(data, 'poll_unexpected{scenario:stressed}', 'rate')}`,
		`- State reflection p95/p99: ${metricValue(data, 'state_reflection_duration', 'p(95)')} / ${metricValue(data, 'state_reflection_duration', 'p(99)')} ms`,
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

function metricValue(data, name, value) {
	const metric = data.metrics[name];
	return metric && metric.values[value] !== undefined ? metric.values[value] : 'n/a';
}

function thresholdEvidence(data) {
	const evidence = [];
	Object.keys(data.metrics).forEach((name) => {
		const thresholds = data.metrics[name].thresholds;
		if (!thresholds) return;
		Object.keys(thresholds).forEach((expression) => {
			const result = thresholds[expression];
			evidence.push(`- ${name} ${expression}: ${result && result.ok === true ? 'PASS' : 'FAIL'}`);
		});
	});
	return evidence;
}
