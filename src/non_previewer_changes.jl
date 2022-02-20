function get_printer(
    module_ts,
    computechan,
    previewchan,
    outchan,
    module_header,
    format,
    verbose,
    hasmany,
    hasbroken,
    maxidw,
    align_overflow,
    interrupted,
    printlock,
    gotprinted,
    num_tests,
    nprinted,
    exception,
)
    printer = @async begin
        errored = false
        finito = false

        print_overall() =
            if module_summary(verbose, hasmany)
                # @assert endswith(module_ts.description, ':')
                if endswith(module_ts.description, ':')
                    module_ts.description = chop(module_ts.description, tail = 1)
                end
                clear_line()
                Testset.print_test_results(
                    module_ts,
                    format,
                    bold = true,
                    hasbroken = hasbroken,
                    maxidw = maxidw[],
                )
            else
                nothing
            end

        # if the previewer overflowed, we must clear the line, otherwise, if
        # what we print now isn't as large, leftovers from the previewer
        # will be seen
        clear_line() =
            if previewchan !== nothing
                # +2: for the final space before spinning wheel and the wheel
                print('\r' * ' '^(format.desc_align + align_overflow + 2) * '\r')
                align_overflow = 0
            end

        while !finito && !interrupted[]
            rts = take!(outchan)
            lock(printlock) do
                if previewchan !== nothing
                    id, desc = take_latest!(previewchan)
                    if desc === nothing
                        # keep `nothing` in so that the previewer knows to terminate
                        put!(previewchan, nothing)
                    end
                end
                gotprinted = true

                if rts === nothing
                    errored && println() # to have empty line after reported error
                    print_overall()
                    finito = true
                    return
                end
                errored && return

                if verbose > 0 || rts.anynonpass
                    clear_line()
                    Testset.print_test_results(
                        rts,
                        format;
                        depth = Int(
                            !rts.overall & isindented(verbose, module_header, hasmany),
                        ),
                        bold = rts.overall | !hasmany,
                        hasbroken = hasbroken,
                        maxidw = maxidw[],
                    )
                end
                if rts.anynonpass
                    # TODO: can we print_overall() here,
                    # without having the wrong numbers?
                    # print_overall()
                    println()
                    Testset.print_test_errors(rts)
                    errored = true
                    allpass = false
                    ndone = num_tests
                end
                nprinted += 1
                if rts.exception !== nothing
                    exception[] = rts.exception
                end
                if nprocs() == 1
                    put!(computechan, nothing)
                end
            end
        end
    end  # printer task
    printer
end

# TODO: Pass ntests by reference. Figure out what else needs passing by ref.
function get_worker(
    mod,
    pat,
    module_ts,
    computechan,
    previewchan,
    outchan,
    module_header,
    ntests,
    format,
    verbose,
    hasmany,
    hasbroken,
    maxidw,
    align_overflow,
    interrupted,
    printlock,
    gotprinted,
    tests,
    nprinted,
    todo,
    exception,
    seed,
)
    worker = @task begin
        printer = get_printer(
            module_ts,
            computechan,
            previewchan,
            outchan,
            module_header,
            format,
            verbose,
            hasmany,
            hasbroken,
            maxidw,
            align_overflow,
            interrupted,
            printlock,
            gotprinted,
            length(tests),
            nprinted,
            exception,
        )

        ndone = 0

        if module_header
            # + if module_header, we print the module as a header, to know where the currently
            #   printed testsets belong
            ntests += 1
            put!(outchan, module_ts) # printer task will take care of feeding computechan
        else
            @async put!(computechan, nothing)
        end

        if seed !== false
            let seedstr = if seed === true
                    # seed!(nothing) doesn't work on old Julia, so we can't just set
                    # `seed = nothing` and interpolate `seed` directly in includestr
                    ""
                else
                    string(seed)
                end, includestr = """
                                  using Random
                                  Random.seed!($seedstr)
                                  nothing
                                  """
                # can't use `@everywhere using Random`, as here is not toplevel
                @everywhere Base.include_string(Main, $includestr)
            end
        end

        @sync for wrkr in workers()
            @async begin
                if nprocs() == 1
                    take!(computechan)
                end
                file = nothing
                idx = 0
                while ndone < length(tests) && !interrupted[]
                    ndone += 1
                    if !@isdefined(groups)
                        ts = tests[ndone]
                    else
                        if file === nothing
                            if isempty(groups)
                                idx = 1
                            else
                                idx, file = popfirst!(groups)
                            end
                        end
                        idx = findnext(todo, idx) # when a wrkr has file==nothing, it might steal an item from group of another
                        # worker, so in any case we must search for a non-done item
                        ts = tests[idx]
                        todo[idx] = false
                        if idx == length(tests) ||
                           file === nothing ||
                           tests[idx+1].source.file != file
                            file = nothing
                        else
                            idx += 1
                        end
                    end

                    if previewchan !== nothing
                        desc = ts.desc
                        desc =
                            desc isa String ? desc : join(replace(desc.args) do part
                                part isa String ? part : "?"
                            end)
                        desc = "\0" * desc
                        # even when nworkers() >= 2, we inform the previewer that
                        # computation is gonna happen, so the wheel can start spinning
                        put!(previewchan, (ts.id, desc))
                    end

                    chan = (out = outchan, compute = computechan, preview = previewchan)
                    resp =
                        remotecall_fetch(wrkr, mod, ts, pat, chan) do mod, ts, pat, chan
                            mts = make_ts(ts, pat, format.stats, chan)
                            Core.eval(mod, mts)
                        end
                    if resp isa Vector
                        ntests += length(resp)
                        append!(module_ts.results, resp)
                    else
                        ntests += 1
                        push!(module_ts.results, resp)
                    end
                end
            end # wrkr task
        end # @sync workers()

        # TODO: maybe put the following stuff in a finally clause where we schedule worker
        # (as part of the mechanism to handle exceptions vs interrupt[])
        put!(outchan, nothing)
        previewchan !== nothing && put!(previewchan, nothing)
        wait(printer)
    end  # worker task
    worker
end

function run_core_task_loop(
    worker_task,
    previewer_task,
    previewchan,
    nthreads,
    version,
    interrupted,
)
    try
        if previewchan !== nothing && nthreads() > 1 && VERSION >= v"1.3"
            # we try to keep thread #1 free of heavy work, so that the previewer stays
            # responsive
            tid = rand(2:nthreads)
            thread_pin(worker_task, UInt16(tid))
        else
            schedule(worker_task)
        end

        wait(worker_task)
        previewer_task !== nothing && wait(previewer_task)

    catch ex
        interrupted[] = true
        ex isa InterruptException || rethrow()
    end
end

# worker = get_worker(
#     mod, pat, module_ts, computechan, previewchan, outchan,
#     module_header, ntests, format, verbose, hasmany, hasbroken, maxidw,
#     align_overflow, interrupted, printlock, gotprinted, tests, nprinted,
#     todo, exception, seed
# )

# run_core_task_loop(
#     worker, previewer, previewchan, nthreads(), VERSION, interrupted
# )
