NAME := geekIpa
SCHEME := geekIpa
PLATFORMS := iphoneos maccatalyst

TMP := $(TMPDIR)/$(NAME)
CERT_JSON_URL := https://backloop.dev/pack.json

.PHONY: all clean deps $(PLATFORMS)

all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

deps:
	rm -rf deps || true
	mkdir -p deps

	# 服务器 TLS 证书来自第三方服务，挂了就跳过（App 内自检会在安装时明确提示，不静默失败）
	curl -fsSL --max-time 30 --retry 2 "$(CERT_JSON_URL)" -o cert.json \
		&& jq -r '.cert' cert.json > deps/server.crt \
		&& jq -r '.key1, .key2' cert.json > deps/server.pem \
		&& jq -r '.info.domains.commonName' cert.json > deps/commonName.txt \
		|| echo "::warning::证书服务不可用，跳过 TLS 证书注入（itms 默认安装通道将不可用，配对文件通道不受影响）"


$(PLATFORMS): deps
	rm -rf _build

	@if [ "$@" = "iphoneos" ]; then \
		DEST="generic/platform=iOS"; \
	else \
		DEST="generic/platform=macOS,variant=Mac Catalyst"; \
	fi; \
	xcodebuild \
		-project geekIpa.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "$$DEST" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/geekIpa.app
	chmod -R 0755 _build/Payload/geekIpa.app
	codesign --force --sign - --timestamp=none _build/Payload/geekIpa.app
	cp deps/* _build/Payload/geekIpa.app/ || true

	mkdir -p packages

	@if [ "$@" = "iphoneos" ]; then \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/geekIpa.ipa"; \
	else \
		ditto -c -k --sequesterRsrc --keepParent _build/Payload/geekIpa.app "packages/geekIpa_Catalyst.zip"; \
	fi
