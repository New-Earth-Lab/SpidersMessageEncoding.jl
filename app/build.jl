using PackageCompiler
if Sys.isapple()
    ENV["JULIA_CC"]="gcc-13"
end
create_app(".", "spidmsg", filter_stdlibs=true, script="src/precompile-workload.jl", force=true)