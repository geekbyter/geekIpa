NAME := geekIpa
SCHEME := geekIpa
PLATFORMS := iphoneos
CATALYST := maccatalyst

TMP := $(TMPDIR)/$(NAME)

.PHONY: all clean $(PLATFORMS) $(CATALYST)

# 默认只出 iOS 产物（Catalyst 见 make maccatalyst）
all: $(PLATFORMS)

clean:
	rm -rf $(TMP)
	rm -rf packages
	rm -rf Payload

# iOS 设备包：需要 macOS + Xcode
iphoneos:
	rm -rf _build

	xcodebuild \
		-project geekIpa.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "generic/platform=iOS" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p _build/Payload
	cp -R _build/Applications/*.app _build/Payload/geekIpa.app
	chmod -R 0755 _build/Payload/geekIpa.app
	codesign --force --sign - --timestamp=none _build/Payload/geekIpa.app

	mkdir -p packages
	ditto -c -k --sequesterRsrc --keepParent _build/Payload "packages/geekIpa.ipa"
	@echo "产物: packages/geekIpa.ipa"

# 可选：Mac Catalyst 桌面版
maccatalyst:
	rm -rf _build

	xcodebuild \
		-project geekIpa.xcodeproj \
		-scheme $(SCHEME) \
		-configuration Release \
		-destination "generic/platform=macOS,variant=Mac Catalyst" \
		-derivedDataPath $(TMP)/$@ \
		-skipPackagePluginValidation \
		CODE_SIGNING_ALLOWED=NO \
		ALWAYS_EMBED_SWIFT_STANDARD_LIBRARIES=NO

	mkdir -p packages
	ditto -c -k --sequesterRsrc --keepParent _build/Applications/geekIpa.app "packages/geekIpa_Catalyst.zip"
	@echo "产物: packages/geekIpa_Catalyst.zip"

# 说明：
#  · 安装走局域网 HTTP（自研 LocalHTTPServer），已不再需要 TLS 证书，
#    因此本文件不下载任何证书，也不往 App 包里塞证书文件。
#  · 云构建见 .github/workflows/build.yml；本 Makefile 仅供本地有 Mac 时使用。
