module Kaleido

import JSON
using Base64
using Kaleido_jll

export savefig

mutable struct Pipes
    stdin::Pipe
    stdout::Pipe
    stderr::Pipe
    proc::Base.Process
    Pipes() = new()
end

const P = Pipes()

const ALL_FORMATS = Set(["png", "jpeg", "webp", "svg", "pdf", "eps", "json"])
const TEXT_FORMATS = Set(["svg", "json", "eps"])
const KALEIDO_MIMES = Dict(
    "application/pdf" => "pdf",
    "image/png" => "png",
    "image/svg+xml" => "svg",
    "image/eps" => "eps",
    "image/jpeg" => "jpeg",
    "image/jpeg" => "jpeg",
    "application/json" => "json",
    "application/json; charset=UTF-8" => "json",
)

function __init__()
    @async _start_kaleido_process()
end

function _restart_kaleido_process()
    if isdefined(P, :proc) && process_running(P.proc)
        kill(P.proc)
    end
    _start_kaleido_process()
end


function _start_kaleido_process()
    global P
    try
        BIN = let
            art = Kaleido_jll.artifact_dir
            cmd = if Sys.islinux() || Sys.isapple()
                joinpath(art, "kaleido")
            else
                # Windows
                joinpath(art, "kaleido.cmd")
            end
            no_sandbox = "--no-sandbox"
            Sys.isapple() ? `$(cmd) plotly --disable-gpu --single-process` : `$(cmd) plotly --disable-gpu $(no_sandbox)`
        end
        kstdin = Pipe()
        kstdout = Pipe()
        kstderr = Pipe()
        kproc = run(pipeline(BIN,
                             stdin=kstdin, stdout=kstdout, stderr=kstderr),
                    wait=false)
        process_running(kproc) || error("There was a problem starting up kaleido.")
        close(kstdout.in)
        close(kstderr.in)
        close(kstdin.out)
        Base.start_reading(kstderr.out)
        P.stdin = kstdin
        P.stdout = kstdout
        P.stderr = kstderr
        P.proc = kproc

        # read startup message and check for errors
        res = readline(P.stdout)
        if length(res) == 0
            error("Could not start Kaleido process")
        end

        js = JSON.parse(res)
        if get(js, "code", 0) != 0
            error("Could not start Kaleido process")
        end
    catch e
        @warn "Kaleido is not available on this system. Julia will be unable to save images of any plots."
        @warn "$e"
    end
    nothing
end

function savefig(
        payload;
        format::String="png"
    )::Vector{UInt8}
    if !(format in ALL_FORMATS)
        error("Unknown format $format. Expected one of $ALL_FORMATS")
    end

    if occursin('\n', payload)
        throw(ArgumentError("`payload` needs to be a valid json string without newline characters."))
    end

    if !occursin("\"format\":", payload)
        ind = findfirst('{', payload)
        payload = string("{", "\"format\": \"", format, "\",", payload[ind+1:end])
    end

    _ensure_kaleido_running()
    # convert payload to vector of bytes
    bytes = transcode(UInt8, payload)
    write(P.stdin, bytes)
    write(P.stdin, transcode(UInt8, "\n"))
    flush(P.stdin)

    # read stdout and parse to json
    res = readline(P.stdout)
    js = JSON.parse(res)

    # check error code
    code = get(js, "code", 0)
    if code != 0
        msg = get(js, "message", nothing)
        error("Transform failed with error code $code: $msg")
    end

    # get raw image
    img = String(js["result"])

    # base64 decode if needed, otherwise transcode to vector of byte
    if format in TEXT_FORMATS
        return transcode(UInt8, img)
    else
        return base64decode(img)
    end
end

"""
    savefig(
        io::IO,
        p;
        format::String="png"
    )
Save a plot `p` to the io stream `io`. They keyword argument `format`
determines the type of data written to the figure and must be one of
$(join(ALL_FORMATS, ", ")).
"""
function savefig(io::IO,
        payload;
        format::String="png")
    bytes = savefig(payload; format)
    write(io, bytes)
end


"""
    savefig(
        p, fn::AbstractString;
        format::Union{Nothing,String}=nothing,
    )
Save a plot `p` to a file named `fn`. If `format` is given and is one of
$(join(ALL_FORMATS, ", ")); it will be the format of the file. By
default the format is guessed from the extension of `fn`.
"""
function savefig(
        payload::String, fn::AbstractString;
        format::Union{Nothing,String}=nothing,
    )
    ext = split(fn, ".")[end]
    if format === nothing
        format = String(ext)
    end

    open(fn, "w") do f
        savefig(f, payload; format)
    end
    return fn
end

_kaleido_running() = isdefined(P, :stdin) && isopen(P.stdin) && process_running(P.proc)
_ensure_kaleido_running() = !_kaleido_running() && _restart_kaleido_process()

end # module Kaleido
