# Contributing

Thanks for your interest. Issues and pull requests are welcome at https://github.com/Duayti/ClaudeUsageWidget.

```sh
git clone https://github.com/Duayti/ClaudeUsageWidget.git
```

## Setup

- macOS 14 or later, Xcode 15 or later, `/usr/bin/python3`.
- `python3 tools/generate_project.py` regenerates `ClaudeUsageWidget.xcodeproj`. Do not edit the project by hand; add new files to the lists at the top of the script.

## Before you open a pull request

Run both test suites:

```sh
xcodebuild test -project ClaudeUsageWidget.xcodeproj -scheme ClaudeUsageWidget \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=-
/usr/bin/python3 -I -m unittest discover -s tools -p 'test_*.py' -v
```

## Guidelines

- Write the test first for behavior changes and bug fixes.
- UI strings go in `Resources/Localizable.xcstrings` (English is the source language; provide a Spanish translation when you can). Format numbers and dates with the user's locale, never with a fixed separator. Tests that format values must pin the locale.
- Code, comments and log messages are in English.
- `tools/update_usage.py` must stay standard-library only and portable.
- Keep the project free of personal data: no absolute home paths, names, emails or bundle identifiers tied to a person.
- Keep pull requests small and focused.

## Unofficial project

This project is not affiliated with Anthropic. Do not add Anthropic or Claude logos or branding.
