.PHONY: server test integration-test start-webhook stop-webhook release

# Start the Phoenix server
server:
	mix phx.server

# Run unit tests
test:
	mix test

# ---- Integration Tests ----

integration-test: start-webhook
	@echo "Running integration tests against http://localhost:4000"
	@echo "Webhook server on http://localhost:9090"
	@echo ""
	@hurl --test \
		--variable EZTHROTTLE_URL=http://localhost:4000 \
		--variable WEBHOOK_URL=http://localhost:9090 \
		--variable WEBHOOK_CALLBACK_URL=http://localhost:9090/webhook \
		--variable timestamp=$$(date +%s) \
		test/integration/*.hurl || \
		(echo "Hurl tests failed"; make stop-webhook; exit 1)
	@echo ""
	@echo "Running SSE streaming tests..."
	@EZTHROTTLE_URL=http://localhost:4000 \
		WEBHOOK_URL=http://localhost:9090 \
		WEBHOOK_CALLBACK_URL=http://localhost:9090/webhook \
		python3 test/integration/test_stream.py || \
		(echo "Streaming tests failed"; make stop-webhook; exit 1)
	@make stop-webhook
	@echo ""
	@echo "All integration tests passed!"

start-webhook:
	@echo "Starting webhook server on port 9090..."
	@python3 test/integration/webhook_server.py 9090 > /tmp/webhook_9090.log 2>&1 & echo $$! > test/integration/.webhook.pid
	@sleep 1
	@echo "Webhook server started (PID $$(cat test/integration/.webhook.pid))"

stop-webhook:
	@if [ -f test/integration/.webhook.pid ]; then \
		kill $$(cat test/integration/.webhook.pid) 2>/dev/null && echo "Webhook server stopped" || true; \
		rm -f test/integration/.webhook.pid; \
	fi

release:
	@if [ -z "$(VERSION)" ]; then echo "Usage: make release VERSION=0.1.0"; exit 1; fi
	@echo "Releasing v$(VERSION)..."
	@git tag -a v$(VERSION) -m "Release v$(VERSION)"
	@git push origin v$(VERSION)
	@gh release create v$(VERSION) --title "v$(VERSION)" --generate-notes
	@echo "Released v$(VERSION)!"
