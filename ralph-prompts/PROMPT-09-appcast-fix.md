# Issue #9: Fix Appcast 1.0.7 Entry

## Goal
Fix the corrupted 1.0.7 entry in `docs/appcast.xml`. The core Sparkle update issue was already fixed in 1.0.9, but the appcast has a stale data bug.

## Problem
In `docs/appcast.xml`, the 1.0.7 entry (lines 25-33) has incorrect values:
- `sparkle:shortVersionString` says `1.0.9` instead of `1.0.7`
- `enclosure url` points to `v1.0.9/ImmiBridge-1.0.9.dmg` instead of `v1.0.7/ImmiBridge-1.0.7.dmg`

This is a copy-paste error from when the 1.0.9 entry was added.

## File to Modify
- `docs/appcast.xml` -- this is the ONLY file that needs changes

## Exact Fix

Change the 1.0.7 item block (lines 25-33) from:
```xml
<item>
    <title>1.0.7</title>
    <pubDate>Wed, 31 Dec 2025 11:37:34 -0800</pubDate>
    <link>https://github.com/emerysilb/immibridge/releases</link>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>1.0.9</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
    <enclosure url="https://github.com/emerysilb/immibridge/releases/download/v1.0.9/ImmiBridge-1.0.9.dmg" length="6076186" type="application/octet-stream" sparkle:edSignature="S/DBUxBGBKoZYY2gxiFOgDbJAHV2I6bUkePEMbeyUpDVqRrFTDqLUfAOrUi7931fCNBRzTEn+FjSgvogcWdvDg=="/>
</item>
```

To:
```xml
<item>
    <title>1.0.7</title>
    <pubDate>Wed, 31 Dec 2025 11:37:34 -0800</pubDate>
    <link>https://github.com/emerysilb/immibridge/releases</link>
    <sparkle:version>2</sparkle:version>
    <sparkle:shortVersionString>1.0.7</sparkle:shortVersionString>
    <sparkle:minimumSystemVersion>12.0</sparkle:minimumSystemVersion>
    <enclosure url="https://github.com/emerysilb/immibridge/releases/download/v1.0.7/ImmiBridge-1.0.7.dmg" length="6076186" type="application/octet-stream" sparkle:edSignature="S/DBUxBGBKoZYY2gxiFOgDbJAHV2I6bUkePEMbeyUpDVqRrFTDqLUfAOrUi7931fCNBRzTEn+FjSgvogcWdvDg=="/>
</item>
```

**Note:** The `sparkle:edSignature` and `length` may also be wrong (they'd be the 1.0.9 signature, not 1.0.7). If the v1.0.7 DMG no longer exists on GitHub releases, it's acceptable to keep the signature as-is since no users are on build 2 anymore. The critical fix is the version string and URL.

## Constraints
- Do NOT modify the 1.0.8 or 1.0.9 entries -- they are correct
- Do NOT change the XML structure or add new entries
- Keep the file well-formed XML

## Verification
1. Read `docs/appcast.xml` and confirm all three items have matching version strings and URLs
2. Verify the XML is well-formed (each `<item>` has matching closing tags)

## Completion
When the fix is applied, output:
<promise>ISSUE 9 FIXED</promise>
