# Flowseal general_fake_tls_auto_alt2 translated to zapret2
# Techniques: fake + multisplit with seqovl=681, badseq fooling (tcp_seq=10000000), tls_mod
#
# Source: zapret-latest/general (FAKE TLS AUTO ALT2).bat
# Tested: 2026-02-20, YouTube + Discord working

TCP_PORTS="80,443,2053,2083,2087,2096,8443"
UDP_PORTS="443,19294-19344,50000-50100"

BLOB_OPTS="\
--blob=quic_google:@$NFQWS2_FAKES/quic_initial_www_google_com.bin \
--blob=tls_google:@$NFQWS2_FAKES/tls_clienthello_www_google_com.bin \
--blob=tls_max_ru:@$FLOWSEAL_BIN/tls_clienthello_max_ru.bin \
--blob=zero_256:@$NFQWS2_FAKES/zero_256.bin \
--blob=stun:@$NFQWS2_FAKES/stun.bin"

read -r -d '' STRATEGY << 'EOF' || true
--filter-udp=443 --filter-l7=quic --hostlist=$LISTS_DIR/list-general.txt --hostlist-exclude=$LISTS_DIR/list-exclude.txt --ipset-exclude=$LISTS_DIR/ipset-exclude.txt --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11
--new
--filter-udp=19294-19344,50000-50100 --filter-l7=discord,stun --lua-desync=fake:blob=zero_256:repeats=6
--new
--filter-tcp=2053,2083,2087,2096,8443 --hostlist-domains=discord.media --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google
--new
--filter-tcp=443 --filter-l7=tls --hostlist=$LISTS_DIR/list-google.txt --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8:tls_mod=rnd,dupsid,sni=www.google.com:ip_id=zero --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google:ip_id=zero
--new
--filter-tcp=80 --filter-l7=http --hostlist=$LISTS_DIR/list-general.txt --hostlist-exclude=$LISTS_DIR/list-exclude.txt --ipset-exclude=$LISTS_DIR/ipset-exclude.txt --payload=http_req --lua-desync=fake:blob=tls_max_ru:tcp_seq=10000000:repeats=8 --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google
--new
--filter-tcp=443 --filter-l7=tls --hostlist=$LISTS_DIR/list-general.txt --hostlist-exclude=$LISTS_DIR/list-exclude.txt --ipset-exclude=$LISTS_DIR/ipset-exclude.txt --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google
--new
--filter-udp=443 --filter-l7=quic --ipset=$LISTS_DIR/ipset-all.txt --hostlist-exclude=$LISTS_DIR/list-exclude.txt --ipset-exclude=$LISTS_DIR/ipset-exclude.txt --payload=quic_initial --lua-desync=fake:blob=quic_google:repeats=11
--new
--filter-tcp=80 --filter-l7=http --ipset=$LISTS_DIR/ipset-all.txt --hostlist-exclude=$LISTS_DIR/list-exclude.txt --ipset-exclude=$LISTS_DIR/ipset-exclude.txt --payload=http_req --lua-desync=fake:blob=tls_max_ru:tcp_seq=10000000:repeats=8 --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google
--new
--filter-tcp=443 --filter-l7=tls --ipset=$LISTS_DIR/ipset-all.txt --hostlist-exclude=$LISTS_DIR/list-exclude.txt --ipset-exclude=$LISTS_DIR/ipset-exclude.txt --payload=tls_client_hello --lua-desync=fake:blob=fake_default_tls:tcp_seq=10000000:repeats=8:tls_mod=rnd,dupsid,sni=www.google.com --lua-desync=multisplit:pos=1:seqovl=681:seqovl_pattern=tls_google
EOF
