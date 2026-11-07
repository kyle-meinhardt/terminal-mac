#!/usr/bin/env python3
"""Exercise the real C bridge against a deterministic loopback RFB/ARD fixture.
No macOS accounts or Keychain credentials are used. Requires libvncserver headers/runtime.
"""
import hashlib, pathlib, socket, struct, subprocess, tempfile, threading

ROOT = pathlib.Path(__file__).resolve().parent.parent
PRIME = int('''FFFFFFFFFFFFFFFFC90FDAA22168C234C4C6628B80DC1CD129024E08
8A67CC74020BBEA63B139B22514A08798E3404DDEF9519B3CD3A431B
302B0A6DF25F14374FE1356D6D51C245E485B576625E7EC6F44C42E9
A637ED6B0BFF5CB6F406B7EDEE386BFB5A899FA5AE9F24117C4B1FE6
49286651ECE45B3DC2007CB8A163BF0598DA48361C55D39A69163FA8FD
24CF5F83655D23DCA3AD961C62F356208552BB9ED529077096966D670C
354E4ABC9804F1746C08CA18217C32905E462E36CE3BE39E772C180E8
6039B2783A2EC07A28FB5C55DF06F4C52C9DE2BCBF695581718399549
7CEA956AE515D2261898FA051015728E5A8AACAA68FFFFFFFFFFFFFFFF'''.replace('\n',''), 16)
PIXELS = bytes([0,0,255,0, 0,255,0,0, 255,0,0,0, 255,255,255,0])

def receive(c, n):
    result = b''
    while len(result) < n:
        chunk = c.recv(n-len(result))
        if not chunk: raise EOFError('client disconnected')
        result += chunk
    return result

def fixture(listener, mode, events, errors):
    try:
        with listener.accept()[0] as c:
            c.settimeout(8)
            if mode == 'plain-rfb':
                c.sendall(b'RFB 003.008\n')
                assert c.recv(12) == b''
                return
            c.sendall(b'RFB 003.889\n')
            assert receive(c,12) == b'RFB 003.889\n'
            if mode == 'no-auth':
                c.sendall(b'\x01\x01')
                # ARD-only client must close rather than choose unauthenticated console access.
                assert c.recv(1) != b'\x01'
                return
            c.sendall(b'\x01\x1e')
            assert receive(c,1) == b'\x1e'
            keylen = 256
            c.sendall(struct.pack('!HH',2,keylen)+PRIME.to_bytes(keylen,'big')+
                      pow(2,12345,PRIME).to_bytes(keylen,'big'))
            material = receive(c,128+keylen)
            assert b'fixture-password' not in material
            client_public = int.from_bytes(material[128:], 'big')
            shared = pow(client_public, 12345, PRIME).to_bytes(keylen, 'big')
            event_key = hashlib.md5(shared).hexdigest()
            if mode == 'reject':
                reason=b'fixture authentication rejected'
                c.sendall(struct.pack('!II',1,len(reason))+reason)
                return
            c.sendall(struct.pack('!I',0))
            assert receive(c,1) == b'\xc1' # shared + enhanced + explicit session selection
            fmt=struct.pack('!BBBBHHHBBB3x',32,24,0,1,255,255,255,16,8,0)
            flags = 0 if mode == 'console-only' else 4
            name = b'\x00\x00'+struct.pack('!I',flags)+bytes(16)+b'fixture-agent\x00'
            size = 0 if mode in ['zero-display','displayinfo2','pseudo1105'] else 2
            c.sendall(struct.pack('!HH',size,size)+fmt+struct.pack('!I',len(name))+name)
            if mode == 'console-only':
                assert c.recv(1) == b''
                return
            info=struct.pack('!HII',1,4,0)+b'fixture-console\x00'
            c.sendall(struct.pack('!H',len(info))+info)
            selection=receive(c,74)
            assert selection[:10] == b'\x00\x48\x00\x01\x00\x00\x00\x00\x02\x00', selection
            assert selection[10:26] == b'fixture-console\x00', selection
            statuses = [1] if mode == 'virtual-denied' else [2,3,4] if mode == 'pending' else [0]
            for status in statuses:
                body=struct.pack('!HI',1,status)+bytes(74)
                c.sendall(struct.pack('!H',len(body))+body)
            if mode == 'virtual-denied':
                assert c.recv(1) == b''
                return
            assert receive(c,66)[0] == 33 # viewer info
            assert receive(c,4) == bytes([10,0,0,1]) # lossless mode
            assert receive(c,8) == bytes([13,1,0,0,0,0,0,0]) # display info request
            assert receive(c,8) == bytes([21,0,0,0,0,0,0,0]) # clipboard disabled
            sent_frame = False
            while True:
                try: kind=receive(c,1)[0]
                except EOFError: break
                if kind == 0: receive(c,19)
                elif kind == 2:
                    header=receive(c,3); encodings=receive(c,struct.unpack('!H',header[1:])[0]*4)
                    assert struct.pack('!i',1101) in encodings
                    if mode in ['displayinfo2','pseudo1105']:
                        body=struct.pack('!HHHHHIIH',1,2,2,2,2,0,0,0)
                        if mode == 'displayinfo2': c.sendall(b'\x51'+struct.pack('!H',len(body))+body)
                        else:
                            c.sendall(b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,2,2,1105)+struct.pack('!H',len(body))+body)
                    if mode == 'zero-display':
                        c.sendall(b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,0,0,1101)+
                                  struct.pack('!HHHH',2,2,1,0)+bytes(28))
                elif kind == 3:
                    receive(c,9)
                    if sent_frame: continue
                    sent_frame = True
                    packet=b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,2,2,0)+PIXELS
                    # Deliberately split rectangle headers/pixels across writes.
                    for i in range(0,len(packet),3): c.sendall(packet[i:i+3])
                elif kind == 9:
                    subscription=receive(c,15)
                    assert subscription[1:3] == b'\x00\x01'
                    assert subscription[-4:] == b'\x00\x02\x00\x02'
                elif kind == 16:
                    payload=receive(c,17)
                    assert payload[0] == 0
                    decrypted=subprocess.run(['/usr/bin/openssl','enc','-d','-aes-128-ecb','-nopad','-K',event_key],
                                             input=payload[1:],capture_output=True,check=True).stdout
                    assert decrypted[0] == 0xff and decrypted[1] in (0,1)
                    assert decrypted[2:6] == b'\x00\x00\x00\x61'
                    events.append(('key',decrypted))
                elif kind == 23:
                    header=receive(c,3)
                    length=struct.unpack('!H',header[1:])[0]
                    body=receive(c,length)
                    assert (length,struct.unpack('!HH',body[:4])) in [(32,(2,8)),(54,(1,11))]
                    assert body[-4:] == b'\x00\x01\x00\x01'
                    if length == 32:
                        line_x,line_y=struct.unpack('!ff',body[4:12])
                        assert abs(line_x+80/45) < 0.001 and abs(line_y-160/45) < 0.001
                    else:
                        assert struct.unpack('!ii',body[22:30]) == (-80,160)
                    events.append(('scroll',body))
                elif kind == 4:
                    raise AssertionError('Plaintext keyboard event is forbidden in enhanced ARD mode')
                elif kind == 5:
                    events.append(('pointer',receive(c,5)))
                else: raise AssertionError(f'unexpected client message {kind}')
    except Exception as exc: errors.append(exc)
    finally: listener.close()

HARNESS = r'''
#include "CVNCBridge.h"
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    TMVNC *c=tm_vnc_create("127.0.0.1",atoi(argv[1]),"fixture-agent","fixture-password");
    if (!c) return 10;
    int connected=tm_vnc_connect(c);
    if (strcmp(argv[2],"success") && strcmp(argv[2],"pending") && strcmp(argv[2],"zero-display") && strcmp(argv[2],"displayinfo2") && strcmp(argv[2],"pseudo1105")) {
        if (connected) return 11;
        tm_vnc_destroy(c); return 0;
    }
    if (!connected) { fprintf(stderr,"%s\n",tm_vnc_error(c)); return 12; }
    if (tm_vnc_width(c)!=2 || tm_vnc_height(c)!=2) return 13;
    if (!tm_vnc_request_frame(c)) return 14;
    const unsigned char expected[]={0,0,255,0,0,255,0,0,255,0,0,0,255,255,255,0};
    for (int i=0;i<40 && (!tm_vnc_sequence(c) || memcmp(tm_vnc_pixels(c),expected,16));i++)
      if (tm_vnc_poll(c,100)<0) return 15;
    if (!tm_vnc_sequence(c) || memcmp(tm_vnc_pixels(c),expected,16)) return 16;
    if (!tm_vnc_key(c,0x61,1) || !tm_vnc_key(c,0x61,0)) return 17;
    if (!tm_vnc_pointer(c,1,1,1) || !tm_vnc_pointer(c,1,1,0)) return 18;
    if (!tm_vnc_pointer(c,1,1,4) || !tm_vnc_pointer(c,1,1,0)) return 19;
    if (!tm_vnc_scroll(c,1,1,80,-160)) return 20;
    tm_vnc_destroy(c); return 0;
}
'''

def main():
    include_paths = [ROOT/'.build/session-library/source/include',ROOT/'.build/session-library/build/include']
    assert all(p.exists() for p in include_paths), 'Run bash scripts/build-session-library.sh first'
    with tempfile.TemporaryDirectory(prefix='terminal-mac-rfb-',dir=ROOT/'.build') as folder:
        folder=pathlib.Path(folder); source=folder/'probe.c'; binary=folder/'probe'
        source.write_text(HARNESS)
        subprocess.run(['clang','-Wall','-Wextra','-Wno-unused-parameter',
                        '-I'+str(ROOT/'Sources/CVNCBridge/include'),*['-I'+str(p) for p in include_paths],
                        str(source),str(ROOT/'Sources/CVNCBridge/bridge.c'),'-o',str(binary)],check=True)
        for mode in ['plain-rfb','no-auth','reject','console-only','virtual-denied','success','pending','zero-display','displayinfo2','pseudo1105']:
            listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(1)
            events=[]; errors=[]
            worker=threading.Thread(target=fixture,args=(listener,mode,events,errors),daemon=True); worker.start()
            result=subprocess.run([str(binary),str(listener.getsockname()[1]),mode],capture_output=True,text=True,timeout=15)
            worker.join(9)
            assert result.returncode == 0, (mode,result.returncode,result.stderr)
            assert not worker.is_alive(), (mode,'fixture did not finish')
            assert not errors, (mode,errors)
            if mode in ['success','pending','zero-display','displayinfo2','pseudo1105']:
                assert [e[0] for e in events] == ['key','key','pointer','pointer','pointer','pointer','scroll','scroll'], events
                assert [events[0][1][1], events[1][1][1]] == [1,0]
                assert events[2][1] == b'\x01\x00\x01\x00\x01',events
                assert events[4][1] == b'\x02\x00\x01\x00\x01',events
            print('PASS:',mode)
if __name__ == '__main__': main()
