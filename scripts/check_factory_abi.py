#!/usr/bin/env python3
"""Check the ZKNOX factory's actual createAccount ABI against what we encode."""
import urllib.request, json, sys

RPC = "https://ethereum-sepolia-rpc.publicnode.com"

def rpc_call(method, params):
    payload = json.dumps({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}).encode()
    req = urllib.request.Request(RPC, data=payload, headers={"Content-Type": "application/json", "User-Agent": "bitchat/1.0"})
    return json.loads(urllib.request.urlopen(req, timeout=10).read())["result"]

# Successful createAccount tx
print("=== Successful createAccount TX ===")
tx = rpc_call("eth_getTransactionByHash", ["0xfde456d9d98f7985729c6abff0c493225f5def9c345df2f943756ad74495541f"])
inp = tx["input"]
sel = inp[:10]
params = inp[10:]

print(f"Selector: {sel}")
off1 = int(params[:64], 16)
off2 = int(params[64:128], 16)
print(f"Offset 1: {off1} (0x{off1:x})")
print(f"Offset 2: {off2} (0x{off2:x})")

len1 = int(params[off1*2:off1*2+64], 16)
len2 = int(params[off2*2:off2*2+64], 16)
print(f"First param (preQuantumPubKey): {len1} bytes")
print(f"Second param (postQuantumPubKey): {len2} bytes")
print(f"Total calldata: {len(inp)//2} bytes")

# First param data
d1_start = off1*2+64
first_param_hex = params[d1_start:d1_start+len1*2]
print(f"First param starts: {first_param_hex[:40]}...")

# Second param data
d2_start = off2*2+64
second_param_hex = params[d2_start:d2_start+40]
print(f"Second param starts: {second_param_hex}...")

print()

# Failed createAccount tx
print("=== Failed createAccount TX ===")
tx2 = rpc_call("eth_getTransactionByHash", ["0x11a7b5630455681d31b6b026c1a8a1d30147ca4caec8fa397f64b2855e307d9c"])
inp2 = tx2["input"]
sel2 = inp2[:10]
params2 = inp2[10:]

print(f"Selector: {sel2}")
if len(params2) >= 128:
    off1b = int(params2[:64], 16)
    off2b = int(params2[64:128], 16)
    print(f"Offset 1: {off1b} (0x{off1b:x})")
    print(f"Offset 2: {off2b} (0x{off2b:x})")
    len1b = int(params2[off1b*2:off1b*2+64], 16)
    len2b = int(params2[off2b*2:off2b*2+64], 16)
    print(f"First param: {len1b} bytes")
    print(f"Second param: {len2b} bytes")
print(f"Total calldata: {len(inp2)//2} bytes")

print()

# Key size summary
print("=== Key Size Analysis ===")
print(f"Successful tx preQuantumPubKey: {len1} bytes")
print(f"Successful tx postQuantumPubKey: {len2} bytes")
print()
print("Expected sizes for mldsa_k1 factory:")
print("  preQuantumPubKey (secp256k1 uncompressed): 64 bytes (no 04 prefix) or 65 bytes (with 04)")
print("  preQuantumPubKey (secp256k1 address): 20 bytes")
print("  postQuantumPubKey (ML-DSA-44 raw): 1312 bytes")
print("  postQuantumPubKey (ML-DSA-44 expanded / Â-hat): ~20480 bytes")
print()

# Check selector match
print("=== Selector Check ===")
print(f"On-chain selector: {sel}")
print(f"Our code uses: keccak256('createAccount(bytes,bytes)')[:4]")
# Check if selectors match by simulating eth_call with our encoded data
