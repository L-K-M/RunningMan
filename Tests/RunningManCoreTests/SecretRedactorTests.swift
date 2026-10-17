import XCTest
@testable import RunningManCore

final class SecretRedactorTests: XCTestCase {
    func testGenericCredentialNamesUseUnderscoreAwareBoundaries() {
        assertRedacted([
            ("RUNNER_SECRET=runner-secret-01", ["runner-secret-01"]),
            ("FORGEJO_TOKEN=forgejo-token-02", ["forgejo-token-02"]),
            ("secret: plain-secret-03", ["plain-secret-03"]),
            (#"{"secret": "quoted-secret-04", "safe": "keep"}"#, ["quoted-secret-04"]),
            ("api_key=api-key-05", ["api-key-05"]),
            ("api-key: api-key-06", ["api-key-06"]),
            ("APIKEY=api-key-07", ["api-key-07"]),
            ("X-Api-Key: header-key-08", ["header-key-08"]),
            (#""private_key": "private-key-09""#, ["private-key-09"]),
            ("passwd=passwd-10", ["passwd-10"]),
            ("client_secret=client-secret-11", ["client-secret-11"]),
            ("AWS_SECRET_ACCESS_KEY=aws-secret-12", ["aws-secret-12"]),
            ("password='single-quoted-13'", ["single-quoted-13"]),
            ("{'token': 'python-token-14'}", ["python-token-14"]),
            (#""password": "two words-15""#, ["two words-15", "words-15"]),
            ("PGPASSWORD=postgres-16 sessionToken=session-17", ["postgres-16", "session-17"])
        ])
        XCTAssertEqual(SecretRedactor.redact(#"{"secret": "quoted-secret-04", "safe": "keep"}"#), #"{"secret": "[REDACTED]", "safe": "keep"}"#)
        XCTAssertEqual(SecretRedactor.redact("password='single-quoted-13' next"), "password='[REDACTED]' next")
        XCTAssertEqual(SecretRedactor.redact("RUNNER_SECRET = runner-secret-01 next"), "RUNNER_SECRET = [REDACTED] next")
        XCTAssertEqual(SecretRedactor.redact(#"{"Authorization": "raw-header-value"}"#), #"{"Authorization": "[REDACTED]"}"#)
    }

    func testTextThatOnlyResemblesCredentialNamesSurvives() {
        assertUnchanged([
            "secretary=front-desk",
            #""isSecret": true"#,
            "isSecret: false",
            "secrets: inherit",
            "uses: actions/checkout@v4 with secret-scanning enabled",
            "--path /tmp/work --patch-level 2 --token-file /tmp/token.txt",
            "cookies: 3 accepted"
        ])
    }

    func testOptionValuesAreRedactedInEveryQuotingStyle() {
        assertRedacted([
            (#"./config.sh --url https://github.com/example/desktop --token "double option-01""#, ["double option-01", "option-01"]),
            ("./config.sh --token 'single option-02'", ["single option-02", "option-02"]),
            ("act_runner register --token=equals-option-03", ["equals-option-03"]),
            ("act_runner register --registration-token registration-option-04 --no-interactive", ["registration-option-04"]),
            ("login --password password-option-05", ["password-option-05"]),
            ("deploy --api-key api-option-06", ["api-option-06"])
        ])
        XCTAssertTrue(SecretRedactor.redact("act_runner register --registration-token value-04 --no-interactive").contains("--no-interactive"))
    }

    func testBearerTokensAndCookieHeadersAreRedacted() {
        assertRedacted([
            ("proxy forwarded bearer abcdefghijklmnop0001 upstream", ["abcdefghijklmnop0001"]),
            ("BEARER ABCDEFGHIJKL0002", ["ABCDEFGHIJKL0002"]),
            (#"curl -H "X-Upstream: Bearer abc.def-ghi_jkl~0003==""#, ["abc.def-ghi_jkl~0003"]),
            ("Cookie: session=cookie-value-04; theme=dark", ["cookie-value-04", "theme=dark"]),
            ("set-cookie: id=cookie-value-05; Path=/; HttpOnly", ["cookie-value-05", "HttpOnly"]),
            (#"{"Cookie": "json-cookie-06"}"#, ["json-cookie-06"]),
            ("token: Bearer abcdefghijklmnop0007", ["abcdefghijklmnop0007"])
        ])
        XCTAssertEqual(SecretRedactor.redact("proxy forwarded bearer abcdefghijklmnop0001 upstream"), "proxy forwarded bearer [REDACTED] upstream")
        assertUnchanged(["Bearer of bad news", "Bearer short12 accepted"])
    }

    func testURLCredentialsAreRedactedForAnySchemeWithoutTouchingPlainUsers() {
        assertRedacted([
            ("connect wss://relay:wss-pass-01@relay.example/socket", ["wss-pass-01"]),
            ("clone ssh://deploy:ssh-pass-02@git.example/example/repo.git", ["ssh-pass-02"]),
            ("clone git://reader:git-pass-03@git.example/example/repo.git", ["git-pass-03"]),
            ("fetch https://user:https-pass-04@forge.example/example/repo.git", ["https-pass-04"]),
            ("fetch https://tokenonlyuserinfo05@forge.example/example/repo.git", ["tokenonlyuserinfo05"]),
            ("fetch HTTPS://x-access-token:upper-pass-06@forge.example/example/repo.git", ["upper-pass-06"])
        ])
        XCTAssertEqual(SecretRedactor.redact("fetch https://user:https-pass-04@forge.example/example/repo.git"),
                       "fetch https://[REDACTED]@forge.example/example/repo.git")
        assertUnchanged([
            "clone https://git@github.com/example/repo.git",
            "clone ssh://git@git.example:2222/example/repo.git",
            "git@github.com:example/repo.git",
            "contact maintainer@example.com for access",
            "https://forge.example:8443/example/repo",
            "https://github.com/example/desktop/actions/runs/123456"
        ])
    }

    func testProviderPrefixedTokensAreRedactedButCommitHashesSurvive() {
        // Built at runtime so the fixtures never look like real credentials to secret scanners.
        let gitlab = "gl" + "pat-" + "FixtureOnly0123456789ab"
        let slack = "xo" + "xb-" + "fixture-value-0001"
        let npm = "np" + "m_" + String(repeating: "f1", count: 18)
        let awsAccess = "AK" + "IA" + "FIXTURETEST00001"
        let awsSession = "AS" + "IA" + "FIXTURETEST00002"
        assertRedacted([gitlab, slack, npm, awsAccess, awsSession].map { ("value \($0) end", [$0]) })
        assertUnchanged([
            "Checking out 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b",
            "AK" + "IA" + "SHORT", "np" + "m_short", "gl" + "pat-short", "xo" + "xb-short"
        ])
    }

    func testPrivateKeyAssignedToCredentialNameKeepsBodyHidden() {
        let safe = SecretRedactor.redact("""
        PRIVATE_KEY: -----BEGIN RSA PRIVATE KEY-----
        private-key-body-that-must-stay-hidden
        -----END RSA PRIVATE KEY-----
        Listener is available
        """)
        XCTAssertFalse(safe.contains("private-key-body-that-must-stay-hidden"), safe)
        XCTAssertTrue(safe.contains("Listener is available"))
    }

    func testUsefulLogTextSurvivesRedaction() {
        assertUnchanged(["""
        [2026-10-16 10:00:00Z INFO Worker] Running job: Build and test (macos-14)
        [2026-10-16 10:00:01Z INFO JobRunner] Checking out 9f86d081884c7d659a2feaa0c55ad015a3bf4f1b in /Users/example/actions-runner/_work/desktop/desktop
        [2026-10-16 10:00:02Z INFO Worker] Workflow: Publish desktop, repository example/desktop
        time="2026-10-16T10:00:03Z" level=info msg="task 42 repo is example/desktop https://forge.example"
        Job result after all job steps finish: Succeeded
        """])
    }

    func testRedactionIsIdempotent() {
        let input = """
        Authorization: Bearer secretbearer
        --token "quoted option" password='single' RUNNER_SECRET=abc
        https://user:pass@forge.example/repo Cookie: a=b
        {"private.setting":{"value":"secret-value","isSecret":true}}
        """
        let once = SecretRedactor.redact(input)
        XCTAssertEqual(SecretRedactor.redact(once), once)
    }

    func testSecretVariableBlocksAreRedactedInAnyKeyOrder() {
        let safe = SecretRedactor.redact("""
        {"variables": {
          "first": {"isSecret": true, "value": "flag-before-value"},
          "second": {"value": "flag-after-value", "isSecret": true},
          "public": {"value": "keep-public-value", "isSecret": false}
        }}
        """)
        XCTAssertFalse(safe.contains("flag-before-value"), safe)
        XCTAssertFalse(safe.contains("flag-after-value"), safe)
        XCTAssertTrue(safe.contains("keep-public-value"))
    }

    func testAdversarialLinesRedactInLinearTime() {
        let size = 256 * 1024
        func line(_ prefix: String = "", repeating fragment: String) -> String {
            prefix + String(repeating: fragment, count: size / fragment.utf8.count + 1)
        }
        let lines = [
            line(repeating: "token=Bearer "),
            line(repeating: "token=\"Bearer token= --token Bearer secret"),
            line(#""k":{"#, repeating: #""isSecret":true,"value":"#),
            line(repeating: #"{"isSecret":true,"value":"x"},"#),
            line("https://", repeating: "a:"),
            line(repeating: "a")
        ]
        for text in lines {
            let elapsed = ContinuousClock().measure { _ = SecretRedactor.redact(text) }
            XCTAssertLessThan(elapsed, .seconds(1), String(text.prefix(40)))
        }
    }

    private func assertRedacted(_ cases: [(String, [String])], file: StaticString = #filePath, line: UInt = #line) {
        for (input, secrets) in cases {
            let safe = SecretRedactor.redact(input)
            XCTAssertTrue(safe.contains("[REDACTED"), "\(input) -> \(safe)", file: file, line: line)
            for secret in secrets { XCTAssertFalse(safe.contains(secret), "\(input) -> \(safe)", file: file, line: line) }
        }
    }

    private func assertUnchanged(_ inputs: [String], file: StaticString = #filePath, line: UInt = #line) {
        for input in inputs { XCTAssertEqual(SecretRedactor.redact(input), input, file: file, line: line) }
    }

    func testSchemeWordDoesNotShieldACredentialValue() {
        XCTAssertEqual(SecretRedactor.redact("token: Basic dXNlcjpwYXNzd29yZA=="), "token: [REDACTED]")
        XCTAssertEqual(SecretRedactor.redact("FORGEJO_TOKEN=token 0123456789abcdef0123"), "FORGEJO_TOKEN=[REDACTED]")
        XCTAssertEqual(SecretRedactor.redact("max_tokens: 512"), "max_tokens: 512")
    }
}
