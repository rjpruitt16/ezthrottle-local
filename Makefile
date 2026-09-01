.PHONY: server test integration-test l8-test start-server stop-server start-webhook stop-webhook start-l8-receiver stop-l8-receiver release \
	region-redirect-deploy region-redirect-test region-redirect-destroy region-redirect-e2e

# Start the Phoenix server
server:
	mix phx.server

# Run unit tests
test:
	mix test

# ---- Integration Tests ----

integration-test: start-server start-webhook
	@echo "Running integration tests against http://localhost:4000"
	@echo "Webhook server on http://localhost:9090"
	@echo ""
	@hurl --test \
		--variable EZTHROTTLE_URL=http://localhost:4000 \
		--variable WEBHOOK_URL=http://localhost:9090 \
		--variable WEBHOOK_CALLBACK_URL=http://localhost:9090/webhook \
		--variable timestamp=$$(date +%s) \
		test/integration/*.hurl || \
		(make stop-webhook stop-server; exit 1)
	@echo ""
	@echo "Running SSE streaming tests..."
	@EZTHROTTLE_URL=http://localhost:4000 \
		WEBHOOK_URL=http://localhost:9090 \
		WEBHOOK_CALLBACK_URL=http://localhost:9090/webhook \
		python3 test/integration/test_stream.py || \
		(make stop-webhook stop-server; exit 1)
	@make stop-webhook stop-server
	@echo ""
	@echo "All integration tests passed!"

l8-test: start-server start-webhook start-l8-receiver
	@echo "Running L8 protocol tests..."
	@echo "  ezthrottle: http://localhost:4000"
	@echo "  target:     http://localhost:9090/health"
	@echo "  receiver:   http://localhost:9001"
	@echo ""
	@EZTHROTTLE_URL=http://localhost:4000 \
		TARGET_URL=http://localhost:9090/health \
		RECEIVER_URL=http://localhost:9001 \
		python3 test/integration/test_l8.py || \
		(make stop-l8-receiver stop-webhook stop-server; exit 1)
	@make stop-l8-receiver stop-webhook stop-server

# ---- Server lifecycle (kill by port — no pid files) ----

start-server:
	@echo "Starting ezthrottle-local on port 4000..."
	@PORT=4000 mix run --no-halt > /tmp/ezthrottle_local.log 2>&1 &
	@until curl -s http://localhost:4000/health > /dev/null 2>&1; do sleep 0.5; done
	@echo "Server ready"

stop-server:
	@lsof -ti :4000 | xargs kill 2>/dev/null || true

start-webhook:
	@echo "Starting webhook server on port 9090..."
	@python3 test/integration/webhook_server.py 9090 > /tmp/webhook_9090.log 2>&1 &
	@until curl -s http://localhost:9090/health > /dev/null 2>&1; do sleep 0.5; done
	@echo "Webhook server ready"

stop-webhook:
	@lsof -ti :9090 | xargs kill 2>/dev/null || true

start-l8-receiver:
	@echo "Starting L8 receiver on port 9001..."
	@python3 test/integration/l8_receiver.py > /tmp/l8_receiver_9001.log 2>&1 &
	@until curl -s http://localhost:9001/.well-known/l8 > /dev/null 2>&1; do sleep 0.5; done
	@echo "L8 receiver ready"

stop-l8-receiver:
	@lsof -ti :9001 | xargs kill 2>/dev/null || true

release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=0.1.0"; exit 1; fi
	@echo "Releasing v$(VERSION)..."
	@git tag -a v$(VERSION) -m "Release v$(VERSION)"
	@git push origin v$(VERSION)
	@gh release create v$(VERSION) --title "v$(VERSION)" --generate-notes
	@echo "Released v$(VERSION)!"

# Real, multi-region cross-region /proxy redirect test against actual
# Fly.io infrastructure -- see test/region_redirect/ and API.md's
# "Cross-region redirect" section. Requires `flyctl auth login` first and
# FLY_ORG set. Deploys two ephemeral, private-only (no public exposure)
# Fly apps; region-redirect-destroy always tears them down, never leaves
# them merely scaled-to-zero.
region-redirect-deploy:
	@./test/region_redirect/deploy.sh

region-redirect-test:
	@./test/region_redirect/test.sh

region-redirect-destroy:
	@./test/region_redirect/destroy.sh

region-redirect-e2e: region-redirect-deploy
	@./test/region_redirect/test.sh; \
	status=$$?; \
	$(MAKE) region-redirect-destroy; \
	exit $$status
