# notchide GUI — dev conveniences.
#
# NOTE: `swift build` / `swift run` need FULL XCODE, not just the Command Line
# Tools: the DynamicNotchKit dependency uses the SwiftUI `@Entry` / `#Preview`
# macros, whose macro plugins ship only inside Xcode.app. On a CLT-only machine
# these targets fail inside the dependency (not in notchide's own code).

.PHONY: build build-lib run generate app clean

## Compile the whole package (library + executable).
build:
	swift build

## Compile just the UI library target (all real code lives here).
build-lib:
	swift build --target NotchideApp

## Run the app from SwiftPM (dev loop).
run:
	swift run notchide

## Generate notchide.xcodeproj from project.yml (needs `brew install xcodegen`).
generate:
	xcodegen generate

## Build the release .app via Xcode.
app: generate
	xcodebuild -project notchide.xcodeproj -scheme notchide -configuration Release build

## Remove build artifacts and the generated project.
clean:
	rm -rf .build notchide.xcodeproj
