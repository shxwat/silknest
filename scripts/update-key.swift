import Foundation
import CryptoKit
// update-key generate <privateKeyFile>   → creates an Ed25519 key (0600), prints the public key (base64)
// update-key sign <privateKeyFile> <message> → prints the base64 signature of the message
let a = CommandLine.arguments
switch a[1] {
case "generate":
    let k = Curve25519.Signing.PrivateKey()
    FileManager.default.createFile(atPath:a[2],contents:k.rawRepresentation,attributes:[.posixPermissions:0o600])
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "public":
    let k = try! Curve25519.Signing.PrivateKey(rawRepresentation:Data(contentsOf:URL(fileURLWithPath:a[2])))
    print(k.publicKey.rawRepresentation.base64EncodedString())
case "sign":
    let k = try! Curve25519.Signing.PrivateKey(rawRepresentation:Data(contentsOf:URL(fileURLWithPath:a[2])))
    print(try! k.signature(for:Data(a[3].utf8)).base64EncodedString())
default: exit(1)
}
