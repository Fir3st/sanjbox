#!/usr/bin/env python3
"""Fixture maintenance ONLY: Python integer pow + Apple's CommonCrypto oracle.

No production crypto, downloaded Python package, network, credential read or OpenSSL.
Published constants: RFC 2409 section 6.2 and RFC 3526 section 3. These obsolete/legacy
profiles are synthetic test data, not a recommendation for live key agreement.
"""
import hashlib
import json
import pathlib
import subprocess
import tempfile

P1024 = """FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE65381
FFFFFFFF FFFFFFFF"""
P2048 = """FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
15728E5A 8AACAA68 FFFFFFFF FFFFFFFF"""

P4096 = """FFFFFFFF FFFFFFFF C90FDAA2 2168C234 C4C6628B 80DC1CD1
29024E08 8A67CC74 020BBEA6 3B139B22 514A0879 8E3404DD
EF9519B3 CD3A431B 302B0A6D F25F1437 4FE1356D 6D51C245
E485B576 625E7EC6 F44C42E9 A637ED6B 0BFF5CB6 F406B7ED
EE386BFB 5A899FA5 AE9F2411 7C4B1FE6 49286651 ECE45B3D
C2007CB8 A163BF05 98DA4836 1C55D39A 69163FA8 FD24CF5F
83655D23 DCA3AD96 1C62F356 208552BB 9ED52907 7096966D
670C354E 4ABC9804 F1746C08 CA18217C 32905E46 2E36CE3B
E39E772C 180E8603 9B2783A2 EC07A28F B5C55DF0 6F4C52C9
DE2BCBF6 95581718 3995497C EA956AE5 15D22618 98FA0510
15728E5A 8AAAC42D AD33170D 04507A33 A85521AB DF1CBA64
ECFB8504 58DBEF0A 8AEA7157 5D060C7D B3970F85 A6E1E4C7
ABF5AE8C DB0933D7 1E8C94E0 4A25619D CEE3D226 1AD2EE6B
F12FFA06 D98A0864 D8760273 3EC86A64 521F2B18 177B200C
BBE11757 7A615D6C 770988C0 BAD946E2 08E24FA0 74E5AB31
43DB5BFC E0FD108E 4B82D120 A9210801 1A723C12 A787E6D7
88719A10 BDBA5B26 99C32718 6AF4E23C 1A946834 B6150BDA
2583E9CA 2AD44CE8 DBBBC2DB 04DE8EF9 2E8EFC14 1FBECAA6
287C5947 4E6BC05D 99B2964F A090C3A2 233BA186 515BE7ED
1F612970 CEE2D7AF B81BDD76 2170481C D0069127 D5B05AA9
93B4EA98 8D8FDDC1 86FFB7DC 90A6C08F 4DF435C9 34063199
FFFFFFFF FFFFFFFF"""

def main():
    package = pathlib.Path(__file__).resolve().parents[1]
    definitions = [
        ("named-rfc3526-maximum-width", P4096, 512, 2, 2, 13, "max-width", "synthetic"),
        ("non-named-rfc2409-leading-zero", P1024, 128, 2, 2, 13, "synthetic", "canary"),
        ("non-named-rfc2409-wire-padding", P1024, 129, 2, 2, 13, "", ""),
        ("non-named-generator-257", P1024, 128, 257, 0x123456789abcdef, 0xfedcba987654321, "u"*63, "p"*64),
        ("named-rfc3526-utf8-nul", P2048, 256, 2, 0x123456789abcdef123456789abcdef, 0xfedcba987654321, "u"*62+"é", "a\0after"),
    ]
    result=[]
    with tempfile.TemporaryDirectory(prefix="a3-vector-oracle-") as temp:
        oracle=pathlib.Path(temp)/"oracle"
        subprocess.run(["/usr/bin/xcrun","clang","-O2","-Wno-deprecated-declarations",
            str(package/"tools/commoncrypto-vector-oracle.c"),"-o",str(oracle)],check=True)
        for name, prime, width, g, x, b, user, password in definitions:
            p=int("".join(prime.split()),16)
            a=pow(g,x,p); y=pow(g,b,p); z=pow(y,x,p)
            assert z==pow(a,b,p)
            enc=lambda n:n.to_bytes(width,"big")
            padding=bytes(range(128))
            plaintext=bytearray(padding)
            for offset,value in [(0,user),(64,password)]:
                field=value.encode("utf-8")[:63]
                plaintext[offset:offset+len(field)]=field
                plaintext[offset+len(field)]=0
            lines=subprocess.run([str(oracle)],input=width.to_bytes(2,"big")+enc(z)+plaintext,
                stdout=subprocess.PIPE,check=True).stdout.decode("ascii").splitlines()
            md5,cipher=lines
            assert md5==hashlib.md5(enc(z)).hexdigest()
            result.append(dict(name=name,generator=g,width=width,modulus=enc(p).hex(),
                privateValue=enc(x).hex(),publicValue=enc(a).hex(),peerValue=enc(y).hex(),
                peerPrivate=enc(b).hex(),sharedValue=enc(z).hex(),padding=padding.hex(),
                username=user,password=password,plaintext=plaintext.hex(),md5=md5,
                response=cipher+enc(a).hex()))
    target=package/"Tests/RFBProtocolTests/Fixtures/type30-vectors.json"
    target.parent.mkdir(parents=True,exist_ok=True)
    target.write_text(json.dumps(result,indent=2,ensure_ascii=True)+"\n")
    print(hashlib.sha256(target.read_bytes()).hexdigest(), target)

if __name__=="__main__":main()
