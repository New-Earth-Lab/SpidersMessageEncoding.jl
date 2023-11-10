# aeronmd must be running during compile workload...
using SpidersMessageEncoding
main([
    "aeron:ipc",
    "1001",
    "--command", "gain=0.0",
    "--command", "leak=0.0",
    "--command", "reconstructor=path.fits"
])
main(String[])
main(["--help"])