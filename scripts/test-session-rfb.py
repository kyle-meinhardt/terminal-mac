#!/usr/bin/env python3
"""Exercise the real C bridge against a deterministic loopback RFB/ARD fixture.
No macOS accounts or Keychain credentials are used. Requires libvncserver headers/runtime.
"""
import hashlib, os, pathlib, socket, struct, subprocess, tempfile, threading, time

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
SUCCESS_MODES = ['success','pending','zero-display','displayinfo2','pseudo1105','partial','retina','encrypted-pointer','encrypted-retina']

def receive(c, n):
    result = b''
    while len(result) < n:
        chunk = c.recv(n-len(result))
        if not chunk: raise EOFError('client disconnected')
        result += chunk
    return result

def fixture(listener, mode, events, errors):
    started = time.monotonic()
    encrypted_pointer = True # Shipping backend accepts encrypted ARD input only
    if mode == 'encrypted-pointer': mode = 'success'
    if mode == 'encrypted-retina': mode = 'retina'
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
            size = 0 if mode in ['zero-display','displayinfo2','pseudo1105','retina'] else 2
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
            partial_complete = False
            dimensions = 4 if mode == 'retina' else 2
            while True:
                try: kind=receive(c,1)[0]
                except EOFError: break
                if kind == 0: receive(c,19)
                elif kind == 2:
                    header=receive(c,3); encodings=receive(c,struct.unpack('!H',header[1:])[0]*4)
                    assert struct.pack('!i',1101) in encodings
                    if mode in ['displayinfo2','pseudo1105','retina']:
                        body=struct.pack('!HHHHHIIH',1,2,2,dimensions,dimensions,0,0,0)
                        if mode in ['displayinfo2','retina']: c.sendall(b'\x51'+struct.pack('!H',len(body))+body)
                        else:
                            c.sendall(b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,2,2,1105)+struct.pack('!H',len(body))+body)
                    if mode == 'zero-display':
                        c.sendall(b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,0,0,1101)+
                                  struct.pack('!HHHH',2,2,1,0)+bytes(28))
                elif kind == 3:
                    receive(c,9)
                    if sent_frame: continue
                    sent_frame = True
                    if mode == 'partial':
                        # Deliberately leave three pixels uninitialized. The harness
                        # must observe sequence zero before requesting the rest.
                        packet=b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,1,1,0)+PIXELS[:4]
                    else:
                        pixels = PIXELS * 4 if mode == 'retina' else PIXELS
                        packet=b'\x00\x00\x00\x01'+struct.pack('!HHHHi',0,0,dimensions,dimensions,0)+pixels
                    # Deliberately split rectangle headers/pixels across writes.
                    for i in range(0,len(packet),3): c.sendall(packet[i:i+3])
                elif kind == 9:
                    subscription=receive(c,15)
                    assert subscription[1:3] == b'\x00\x01'
                    assert subscription[-4:] == struct.pack('!HH',dimensions,dimensions)
                elif kind == 16:
                    payload=receive(c,17)
                    assert payload[0] == 0
                    decrypted=subprocess.run(['/usr/bin/openssl','enc','-d','-aes-128-ecb','-nopad','-K',event_key],
                                             input=payload[1:],capture_output=True,check=True).stdout
                    if decrypted[0] == 0xff:
                        assert decrypted[1] in (0,1)
                        assert struct.unpack('!I',decrypted[2:6])[0] in [0x61,0xffe1,0xffe7,0xffe8,0xffe9,0xffea]
                        timestamp=struct.unpack('!I',decrypted[6:10])[0]
                        # Connection-relative monotonic microseconds, never truncated
                        # wall-clock time (which macOS silently drops for literal text).
                        assert 0 < timestamp <= (time.monotonic()-started)*1_000_000+100_000, timestamp
                        assert decrypted[10:] == bytes(6)
                        events.append(('key',decrypted))
                    elif decrypted[10] == 0xff:
                        assert encrypted_pointer, 'Default pointer unexpectedly changed wire format'
                        assert decrypted[:10] == bytes(10)
                        assert decrypted[11] in (0,1,2,3,4,8,16)
                        if mode == 'partial' and not partial_complete and decrypted[11:] == bytes(5):
                            # The marker is sent only after the C harness proves
                            # partial pixels have not been published as a frame.
                            partial_complete = True
                            packet=(b'\x00\x00\x00\x02'+struct.pack('!HHHHi',1,0,1,1,0)+PIXELS[4:8]+
                                    struct.pack('!HHHHi',0,1,2,1,0)+PIXELS[8:])
                            c.sendall(packet)
                        else:
                            assert decrypted[12:] == struct.pack('!HH',dimensions//2,dimensions//2)
                            events.append(('pointer',decrypted[11:]))
                    else: raise AssertionError('Unrecognized encrypted input event')
                elif kind == 23:
                    raise AssertionError('Unreliable Apple gesture events must not be emitted')
                elif kind == 4:
                    raise AssertionError('Plaintext keyboard event is forbidden in enhanced ARD mode')
                elif kind == 5:
                    raise AssertionError('Plaintext pointer event is forbidden in enhanced ARD mode')
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
    if (strcmp(argv[2],"success") && strcmp(argv[2],"pending") && strcmp(argv[2],"zero-display") && strcmp(argv[2],"displayinfo2") && strcmp(argv[2],"pseudo1105") && strcmp(argv[2],"partial") && strcmp(argv[2],"retina") && strcmp(argv[2],"encrypted-pointer") && strcmp(argv[2],"encrypted-retina")) {
        if (connected) return 11;
        tm_vnc_destroy(c); return 0;
    }
    if (!connected) { fprintf(stderr,"%s\n",tm_vnc_error(c)); return 12; }
    int dimensions = strstr(argv[2],"retina") ? 4 : 2;
    if (tm_vnc_width(c)!=dimensions || tm_vnc_height(c)!=dimensions) return 13;
    if (!tm_vnc_request_frame(c)) return 14;
    const unsigned char pattern[]={0,0,255,0,0,255,0,0,255,0,0,0,255,255,255,0};
    unsigned char expected[64];
    for (int i=0;i<4;i++) memcpy(expected+i*16,pattern,16);
    if (!strcmp(argv[2],"partial")) {
        for (int i=0;i<40 && tm_vnc_pixels(c)[2]!=255;i++)
          if (tm_vnc_poll(c,100)<0) return 21;
        if (tm_vnc_pixels(c)[2]!=255 || tm_vnc_sequence(c)!=0) return 22;
        for (int i=4;i<16;i++) if (tm_vnc_pixels(c)[i]!=0) return 23;
        if (!tm_vnc_pointer(c,0,0,0)) return 24; /* unlock remaining fixture tiles */
    }
    for (int i=0;i<40 && (!tm_vnc_sequence(c) || memcmp(tm_vnc_pixels(c),expected,dimensions*dimensions*4));i++)
      if (tm_vnc_poll(c,100)<0) return 15;
    if (!tm_vnc_sequence(c) || memcmp(tm_vnc_pixels(c),expected,dimensions*dimensions*4)) return 16;
    if (!tm_vnc_key(c,0x61,1) || !tm_vnc_key(c,0x61,0)) return 17;
    const unsigned int modifiers[]={0xffe7,0xffe9,0xffe8,0xffea};
    for (int i=0;i<4;i++)
      if (!tm_vnc_key(c,modifiers[i],1) || !tm_vnc_key(c,modifiers[i],0)) return 25;
    int coordinate = dimensions/2;
    if (!tm_vnc_pointer(c,coordinate,coordinate,1) || !tm_vnc_pointer(c,coordinate,coordinate,0)) return 18;
    if (!tm_vnc_pointer(c,coordinate,coordinate,4) || !tm_vnc_pointer(c,coordinate,coordinate,0)) return 19;
    if (strstr(argv[2],"encrypted-")) {
        /* Exercise middle and simultaneous left+right button normalization. */
        if (!tm_vnc_pointer(c,coordinate,coordinate,2) || !tm_vnc_pointer(c,coordinate,coordinate,0)) return 26;
        if (!tm_vnc_pointer(c,coordinate,coordinate,5) || !tm_vnc_pointer(c,coordinate,coordinate,0)) return 27;
    }
    if (tm_vnc_scroll(c,coordinate,coordinate,3,-5)) return 30;
    if (!tm_vnc_scroll(c,coordinate,coordinate,0,-5)) return 20;
    if (tm_vnc_scroll(c,coordinate,coordinate,1001,0)) return 28;
    if (tm_vnc_scroll(c,dimensions,coordinate,0,-80)) return 29;
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
        for mode in ['plain-rfb','no-auth','reject','console-only','virtual-denied'] + SUCCESS_MODES:
            listener=socket.socket(); listener.bind(('127.0.0.1',0)); listener.listen(1)
            events=[]; errors=[]
            worker=threading.Thread(target=fixture,args=(listener,mode,events,errors),daemon=True); worker.start()
            environment=dict(os.environ)
            environment.pop('TERMINAL_MAC_VNC_KEY_DELAY_MS',None)
            environment.pop('TERMINAL_MAC_VNC_POINTER_ENCRYPTED',None)
            result=subprocess.run([str(binary),str(listener.getsockname()[1]),mode],capture_output=True,text=True,timeout=15,env=environment)
            worker.join(9)
            assert result.returncode == 0, (mode,result.returncode,result.stderr)
            assert not worker.is_alive(), (mode,'fixture did not finish')
            assert not errors, (mode,errors)
            if mode in SUCCESS_MODES:
                pointer_count = 8 if mode.startswith('encrypted-') else 4
                vertical_ticks = 3 if mode in ['retina','encrypted-retina'] else 5
                assert [e[0] for e in events] == ['key']*10 + ['pointer']*(pointer_count+vertical_ticks*2), events
                assert [event[1][1] for event in events[:10]] == [1,0]*5
                timestamps=[struct.unpack('!I',event[1][6:10])[0] for event in events if event[0] == 'key']
                assert timestamps == sorted(timestamps), timestamps
                assert all(timestamps[i+1]-timestamps[i] >= 15_000 for i in range(0,len(timestamps),2)), timestamps
                assert [struct.unpack('!I',event[1][2:6])[0] for event in events[:10]] == [0x61]*2+[0xffe9]*2+[0xffe7]*2+[0xffea]*2+[0xffe8]*2
                coordinate = 2 if mode in ['retina','encrypted-retina'] else 1
                assert events[10][1] == b'\x01'+struct.pack('!HH',coordinate,coordinate),events
                assert events[12][1] == b'\x02'+struct.pack('!HH',coordinate,coordinate),events
                if mode.startswith('encrypted-'):
                    assert events[14][1] == b'\x04'+struct.pack('!HH',coordinate,coordinate),events
                    assert events[16][1] == b'\x03'+struct.pack('!HH',coordinate,coordinate),events
                wheel_start = 10 + pointer_count
                position=struct.pack('!HH',coordinate,coordinate)
                assert [event[1] for event in events[wheel_start:]] == [bytes([mask])+position for mask in [16,0]*vertical_ticks], events
            print('PASS:',mode)
if __name__ == '__main__': main()
