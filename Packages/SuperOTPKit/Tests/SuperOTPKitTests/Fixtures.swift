import Foundation

/// CloudOTP backup JSON fixture (same as the Android project).
let backupFixture = #"""
{
  "schemaVersion": 2,
  "createdAt": 1700000000000,
  "appVersion": "2.0.0",
  "sourceDevice": "fixture",
  "tokenCount": 3,
  "categoryCount": 1,
  "bindingCount": 2,
  "tokens": [
    {
      "id": 1,
      "uid": "totp-1",
      "seq": 1,
      "issuer": "Google",
      "secret": "JBSWY3DPEHPK3PXP",
      "account": "user@example.com",
      "image_path": "google.png",
      "token_type": 0,
      "algorithm": "SHA1",
      "digits": 6,
      "counter": 0,
      "period": 30,
      "pinned": 1,
      "create_timestamp": 1700000000000,
      "edit_timestamp": 1700000001000,
      "remark": "{}",
      "copy_times": 0,
      "pin": "",
      "last_copy_timestamp": 0,
      "description": "",
      "tags": ""
    },
    {
      "id": 2,
      "uid": "hotp-1",
      "seq": 2,
      "issuer": "GitHub",
      "secret": "JBSWY3DPEHPK3PXP",
      "account": "octocat",
      "image_path": "",
      "token_type": 1,
      "algorithm": "SHA256",
      "digits": 8,
      "counter": 7,
      "period": 30,
      "pinned": 0,
      "create_timestamp": 1700000002000,
      "edit_timestamp": 1700000002000,
      "remark": "{}",
      "copy_times": 2,
      "pin": "",
      "last_copy_timestamp": 0,
      "description": "work",
      "tags": "ci"
    },
    {
      "id": 3,
      "uid": "steam-1",
      "seq": 3,
      "issuer": "Steam",
      "secret": "JBSWY3DPEHPK3PXP",
      "account": "player",
      "image_path": "steam.png",
      "token_type": 3,
      "algorithm": "SHA1",
      "digits": 5,
      "counter": 0,
      "period": 30,
      "pinned": 0,
      "create_timestamp": 1700000003000,
      "edit_timestamp": 1700000003000,
      "remark": "{}",
      "copy_times": 0,
      "pin": "",
      "last_copy_timestamp": 0,
      "description": "",
      "tags": ""
    }
  ],
  "categories": [
    {
      "id": 10,
      "uid": "cat-1",
      "seq": 0,
      "title": "Work",
      "description": "office",
      "create_timestamp": 1700000000000,
      "edit_timestamp": 1700000000000,
      "pinned": 0,
      "remark": "{}",
      "bindings": "totp-1,hotp-1"
    }
  ]
}
"""#

/// The fixture above (issuer of the first token changed to "Google 谷歌"), encrypted by an independent
/// implementation (Python argon2-cffi + cryptography AES-GCM) with password "correct horse".
let pythonEncryptedBackup = """
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
W/c0nW/7gw==
"""
