# Network settings. No ARP table or ARP engine is instantiated.
# DEST_MAC defaults to Ethernet broadcast for initial direct-cable testing.
# Replace it with your PC NIC MAC for unicast, e.g. 48'h001122334455.
set ad9226_generics [list \
    DECIMATION=16 \
    SAMPLES_PER_PACKET=512 \
    SOURCE_MAC=48'h020000000001 \
    DEST_MAC=48'hffffffffffff \
    SOURCE_IP=32'hc0a80a02 \
    DEST_IP=32'hc0a80a01 \
    DEST_PORT=16'd5000]
