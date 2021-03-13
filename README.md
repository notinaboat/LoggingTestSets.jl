# LoggingTestSets

`LoggingTestSet` is an [`AbstractTestSet`](https://docs.julialang.org/en/v1/stdlib/Test/#Creating-Custom-AbstractTestSet-Types) that logs test results using `@info` and `@error` from the [Logging][https://docs.julialang.org/en/v1/stdlib/Logging/] module.

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

`TestFileLogger` is an [`AbstractLogger`](https://docs.julialang.org/en/v1/stdlib/Logging/#AbstractLogger-interface) that writes log messages to a file.

```julia
julia> using LoggingTestSets
julia> using Logging
julia> using LoggingExtras
julia> tee = TeeLogger(global_logger(), TestFileLogger("test.log"))

julia> global_logger(tee)
```

