# aeronmd must be running during compile workload...
using SpidersMessageEncodingApp
SpidersMessageEncodingApp.main([
    "aeron:ipc",
    "1001",
    "--command", "gain=0.0",
    "--command", "leak=0.0",
    "--command", "reconstructor=path.fits"
])
SpidersMessageEncodingApp.main(String[])
SpidersMessageEncodingApp.main(["--help"])