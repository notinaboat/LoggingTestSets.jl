"""
# LoggingTestSets

`LoggingTestSet` is an [`AbstractTestSet`](https://docs.julialang.org/en/v1/stdlib/Test/#Creating-Custom-AbstractTestSet-Types)
that logs test results using `@info` and `@error` from the
[Logging][https://docs.julialang.org/en/v1/stdlib/Logging/] module.

```julia
julia> using LoggingTestSets
julia> using Test
julia> @testset LoggingTestSet "Some tests" begin
           @test 1 == 1
           @test 1 == 2
       end

┌ Error: Some tests: Test Failed at REPL[6]:3
│   Expression: 1 == 2
│    Evaluated: 1 == 2
└ @ LoggingTestSets LoggingTestSets/src/LoggingTestSets.jl:49
┌ Info: Test Summary: Some tests
│   passes = 1
│   fails = 1
│   errors = 0
└   broken = 0
Test Summary: | Pass  Fail  Total
Some tests    |    1     1      2
┌ Error: Some tests did not pass: 1 passed, 1 failed, 0 errored, 0 broken.
└ @ LoggingTestSets LoggingTestSets/src/LoggingTestSets.jl:69
ERROR: Some tests did not pass: 1 passed, 1 failed, 0 errored, 0 broken.
```


`TestFileLogger` is an [`AbstractLogger`](https://docs.julialang.org/en/v1/stdlib/Logging/#AbstractLogger-interface)
that writes log messages to a file.

```julia
julia> using LoggingTestSets
julia> using Logging
julia> using LoggingExtras
julia> tee = TeeLogger(global_logger(), TestFileLogger("test.log"))

julia> global_logger(tee)
```
"""
module LoggingTestSets
export LoggingTestSet
export TestFileLogger

using Test
using Test: DefaultTestSet, AbstractTestSet, Fail, Error, scrub_backtrace

using Logging
using LoggingExtras
using DataStructures

using Dates: now


# Logging test results.

struct LoggingTestSet <: AbstractTestSet
    ts::DefaultTestSet
    LoggingTestSet(args...; kw...) = new(DefaultTestSet(args...; kw...))
end


function Test.record(ts::LoggingTestSet, t::Union{Fail, Error})

    io = IOBuffer()

    begin # copied from: stdlib/Test/src/Test.jl https://git.io/JqZQk
        print(io, ts.ts.description, ": ")
        # don't print for interrupted tests
        if !(t isa Error) || t.test_type !== :test_interrupted
            print(io, t)
            if !isa(t, Error) # if not gets printed in the show method
                Base.show_backtrace(io, scrub_backtrace(backtrace()))
            end
            println(io)
        end
    end

    @error String(take!(io))

    push!(ts.ts.results, t)
end

Test.record(ts::LoggingTestSet, args...) = Test.record(ts.ts, args...)


function Test.finish(ts::LoggingTestSet)

    # Copied from: stdlib/Test/src/Test.jl https://git.io/JqZ70
    np, nf, ne, nb, ncp, ncf, nce, ncb = Test.get_test_counts(ts.ts)
    passes = np + ncp
    fails  = nf + ncf
    errors = ne + nce
    broken = nb + ncb

    @info "Test Summary: $(ts.ts.description)" passes fails errors broken

    try
        Test.finish(ts.ts)
    catch err
        @error err
        rethrow(err)
    end
end



# Logging Failure Context.

struct TestFailContextLogger{T <: AbstractLogger, L} <: AbstractLogger
    logger::T
    buffer::CircularBuffer{Tuple}
    TestFailContextLogger(l::T) = new(l, buffer::CircularBuffer{Tuple}(5)) where T
end

function Logging.handle_message(logger::TestFailContextLogger,
                                level, message, _module, group, id, file, line;
                                kwargs...)
    if !comp_shouldlog(logger.logger, level, _module, group, id)
        return
    end

    args = (level, message, _module, group, id, file, line),
    if contains(message, "Test Failed")
        while !isempty(logger.buffer)
            a, k = popfirst!(logger.buffer)
            handle_message(logger.logger, a...; k...)
        end
        handle_message(logger.logger, args...; kwargs...)
    else
        push!(logger.buffer, (args, kwargs))
    end
end

Logging.shouldlog(logger::TestFailContextLogger, args...) = true
Logging.min_enabled_level(logger::TestFailContextLogger) = Logging.BelowMinLevel
Logging.catch_exceptions(logger::TestFailContextLogger) = catch_exceptions(logger.logger)




# Logging to file.

struct TestFileLogger <: AbstractLogger
    io::IO
    TestFileLogger(filename) = new(open(filename, append=true))
end


Logging.shouldlog(::TestFileLogger, args...) = true
Logging.min_enabled_level(::TestFileLogger) = Logging.BelowMinLevel
Logging.catch_exceptions(::TestFileLogger) = false


function Logging.handle_message(l::TestFileLogger, 
                                level, message, _module, group, id, file, line;
                                kwargs...)

    # Copied from: base/logging.jl https://git.io/JqZ5Q
    msglines = split(chomp(string(message)), '\n')

    # Copied from: ConsoleLogger.jl https://git.io/JqZdY
    valbuf=IOBuffer()
    for (key,val) in pairs(kwargs)
        Logging.showvalue(valbuf, val)
        vallines = split(String(take!(valbuf)), '\n')
        if length(vallines) == 1
            push!(msglines, "$key = $(vallines[1])")
        else
            push!(msglines, "$key =")
            append!(msglines, vallines)
        end
    end

    # Copied from: base/logging.jl https://git.io/JqZ5Q
    println(l.io, "┌ ", string(level), " ", now(),  ": ", msglines[1])
    for i in 2:length(msglines)
        println(l.io, "│ ", msglines[i])
    end
    println(l.io, "└ @ ", _module, " ", basename(file), ":", line)
    flush(l.io)
    nothing
end


# Documentation.

readme() = Docs.doc(@__MODULE__)



end # module
