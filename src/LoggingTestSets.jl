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
export ColumnFileLogger
export ColumnConsoleLogger
export RepetitionFilteredLogger

using Test
using Test: DefaultTestSet, AbstractTestSet, Fail, Error, scrub_backtrace

using Logging
using LoggingExtras
using DataStructures
using Crayons
using Dates: now, today, DateTime, Time, Millisecond, Nanosecond,
             unix2datetime, datetime2unix, format, microsecond


# Logging test results.

mutable struct LoggingTestSet <: AbstractTestSet
    ts::DefaultTestSet
    test_name::String
    function LoggingTestSet(name; kw...)
        @info "Test Set: $name"
        new(DefaultTestSet(name; kw...), "")
    end
end

function set_test_name(s::String)
    Test.get_testset().test_name = s
end

function Test.record(ts::LoggingTestSet, t::Union{Fail, Error})

    io = IOBuffer()

    ts.test_name == "" || @warn ts.test_name
    begin # copied from: stdlib/Test/src/Test.jl https://git.io/JqZQk
        print(io, ts.ts.description, ": ")
        # don't print for interrupted tests
        if !(t isa Error) || t.test_type !== :test_interrupted
            print(io, t)
            if t isa Error # if not gets printed in the show method
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


    if fails + errors + broken == 0
        @info "Test Set: $(ts.ts.description) -- All tests passed."
    else
        @info "Test Summary: $(ts.ts.description)" passes fails errors broken
    end

    try
        Test.finish(ts.ts)
    catch err
        @error err
        rethrow(err)
    end
end



# Logging Failure Context.

struct TestFailContextLogger{T <: AbstractLogger} <: AbstractLogger
    logger::T
    buffer::CircularBuffer{Tuple}
    TestFailContextLogger(l::T) where T = new{T}(l, buffer::CircularBuffer{Tuple}(5))
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



# Logging to file with columns.

const default_width = 160

struct ColumnFileLogger <: AbstractLogger
    io::IO
    width::Int
    tzero::Float64
    ColumnFileLogger(io::IO, width) =
        new(io, width, seconds_since_epoch_at_local_midnight())
    ColumnFileLogger(filename; width=default_width) =
        new(open(filename, append=true), width)
end

function seconds_since_epoch_at_local_midnight()
    localtime = now()
    unix_s = time()
    timezone_ms = Millisecond(localtime - unix2datetime(unix_s))
    timezone_s = round(timezone_ms.value / 1000)
    midnight_unix_s = datetime2unix(DateTime(today()))
    return midnight_unix_s - timezone_s
end

function log_time(tzero::Float64, unix_s::Float64)
    ns = try
        round(Int64, 1e9 * (unix_s - tzero))
    catch
        0
    end
    t = Time(Nanosecond(ns))
    format(t, "HH:MM:SS.sss") * string(microsecond(t)÷100)
end

function ColumnConsoleLogger()
    display_height, display_width = displaysize(stdout)
    return ColumnFileLogger(stdout, display_width)
end

Logging.shouldlog(::ColumnFileLogger, args...) = true
Logging.min_enabled_level(::ColumnFileLogger) = Logging.BelowMinLevel
Logging.catch_exceptions(::ColumnFileLogger) = false

function Logging.handle_message(l::ColumnFileLogger, args...; kwargs...)
    write(l.io, column_format_log(l.width, l.tzero, args...; kwargs...))
    flush(l.io)
    nothing
end

function column_format_log(width, tzero,
                           level, message, _module, group, id, file, line;
                           timestamp=time(), kwargs...)
    
    # Split message into lines.
    # Copied from: base/logging.jl https://git.io/JqZ5Q
    msglines = split(chomp(string(message)), '\n')

    # Append lines for extra log args.
    # Copied from: ConsoleLogger.jl https://git.io/JqZdY
    valbuf=IOBuffer()
    for (key,val) in kwargs
        Logging.showvalue(valbuf, val)
        vallines = split(String(take!(valbuf)), '\n')
        if length(vallines) == 1
            push!(msglines, "$key = $(vallines[1])")
        else
            push!(msglines, "$key =")
            append!(msglines, vallines)
        end
    end

    # Prepare prefix, file:line, and stuffix.
    prefix = length(msglines) > 1 ? "┌ " : "[ "
    fileline = string(basename(file), ":", rpad(string(line), 4))
    if group != _module
        fileline = "$group:$fileline"
    end
    suffix = length(msglines) == 1 ? fileline : ""

    # Calculate column widths and padding.
    widths = [2, 5, 1, # level
                13, 1, # time
                20, 3, # module
                try
                    textwidth(msglines[1])
                catch
                    length(msglines[1])
                end,
                textwidth(suffix)]
    pad = max(0, width - sum(widths))

    # Colours.
    bg = module_background(string(_module))
    lc = level_color(level)
    dim = dim_color

    buffer = IOBuffer()

    if timestamp isa String
        timestring = timestamp
    else
        timestring = log_time(tzero, timestamp)
    end

    # Print the first line:
    #
    # ┌ Level 10:11:05.339  Module │ Log Message [ ----- pad ----- ] file:line
    print(buffer,
          "\n",
          bg,
          lc,  prefix, lpad(string(level), widths[2]),  inv(lc),  " ",
          dim,         rpad(timestring,    widths[4]),  inv(dim), " ",
                       lpad(_module,       widths[6]),            " │ ",
                       msglines[1],        repeat(" ", pad),
          dim,         suffix,                          inv(dim),
          inv(bg)
    )

    # Print the other lines.
    #
    # │ [ -------- pad1 -------- ] │ msglines[2] [ ---------- pad2 ----------]
    # │ [ -------- pad1 -------- ] │ msglines[3...] [ -------- pad2 ---------]                   
    # └------------------------------------------------------------- file:line
    if length(msglines) > 1
        # Copied from: base/logging.jl https://git.io/JqZ5Q
        for i in 2:length(msglines)
            pad1 = sum(widths[2:6])
            pad2 = max(0, width - pad1 - 5 - textwidth(msglines[i]))
            print(buffer, "\n",
                          bg,
                          lc, "│ ", inv(lc),
                          repeat(" ", pad1), " │ ",
                          msglines[i],
                          repeat(" ", pad2),
                          inv(bg))
        end
        pad = max(0, width - length(fileline) - 2)
        print(buffer, "\n",
                      bg,
                      lc, "└", repeat("─", pad), inv(lc), " ",
                      dim, fileline, inv(dim),
                      inv(bg))
    end

    return String(take!(buffer))
end



# Repetition Filtered Logger


mutable struct RepetitionFilteredLogger{T <: AbstractLogger} <: AbstractLogger
    logger::T
    max_level::Logging.LogLevel
    modules::Tuple
    last_log::Union{Nothing,NamedTuple}
    timestamp::Float64
    timelimit::Float64
    count::Int
    RepetitionFilteredLogger(l::T; modules=(),
                                   max_level=Logging.Info,
                                   timelimit=1) where T =
        new{T}(l, max_level, modules, nothing, 0, timelimit, 0)
end

Logging.min_enabled_level(f::RepetitionFilteredLogger) = Logging.min_enabled_level(f.logger)
Logging.catch_exceptions(f::RepetitionFilteredLogger) = Logging.catch_exceptions(f.logger)
Logging.shouldlog(f::RepetitionFilteredLogger, args...) = LoggingExtras.comp_shouldlog(f.logger, args...)



function Logging.handle_message(filter::RepetitionFilteredLogger, args...; kwargs...)
    t = time()
    log = LoggingExtras.handle_message_args(args...; kwargs...)

    if log.level <= filter.max_level &&
	log._module in filter.modules

        if filter.last_log != nothing
            if t < filter.timestamp + filter.timelimit &&
            log.id == filter.last_log.id &&
            log._module == filter.last_log._module &&
            log.message == filter.last_log.message

                filter.count += 1
                return
            end
			if filter.count > 0
				Logging.handle_message(filter.logger,
									   filter.last_log.level,
									   string("(repeated x ", filter.count, ") ", filter.last_log.message),
									   filter.last_log._module,
									   filter.last_log.group,
									   filter.last_log.id,
									   filter.last_log.file,
									   filter.last_log.line;
									   kwargs...)
			end
        end

        filter.last_log = log
        filter.timestamp = t
        filter.count = 0
    end

    Logging.handle_message(filter.logger, args...; kwargs...)
end



# Colours.

const dim_color = crayon"fg:246"


level_color(level) = level < Logging.Info  ? crayon"blue" :
                     level < Logging.Warn  ? crayon"cyan" :
                     level < Logging.Error ? crayon"yellow" :
                                             crayon"light_red"


const module_backgrounds = Dict{String, Crayon}(
    "LoggingTestSets" => crayon"bg:16"
)

function module_background(m)
    bg = get(module_backgrounds, m, nothing)
    if bg != nothing
        return bg
    end
    bg = popfirst!(background_colors)
    module_backgrounds[m] = bg
    return bg
end

const background_colors =
    Iterators.Stateful(
    Iterators.Cycle([
    #crayon"bg:16",
    #crayon"bg:18",
    crayon"bg:233",
    crayon"bg:234",
    crayon"bg:235",
    crayon"bg:236",
    crayon"bg:237",
    crayon"bg:238",
    crayon"bg:239",
    crayon"bg:240",
    crayon"bg:241",
    crayon"bg:242",
    crayon"bg:17",
    crayon"bg:18",
    crayon"bg:19",
    crayon"bg:20",
    crayon"bg:21",
    crayon"bg:22",
    crayon"bg:23",
    crayon"bg:24",
    crayon"bg:25",
    crayon"bg:58",
    crayon"bg:59",
    crayon"bg:60",]))




# Documentation.

readme() = Docs.doc(@__MODULE__)



end # module
