@testset "inference.jl" begin
    # Only test threading if 1.3+.
    if VERSION > v"1.2"
        @testset "threaded sampling" begin
            # Test that chains with the same seed will sample identically.
            @testset "rng" begin
                model = gdemo_default

                # multithreaded sampling with PG causes segfaults on Julia 1.5.4
                # https://github.com/TuringLang/Turing.jl/issues/1571
                samplers = @static if VERSION <= v"1.5.3" || VERSION >= v"1.6.0"
                    (
                        HMC(0.1, 7),
                        PG(10),
                        IS(),
                        MH(),
                        Gibbs(PG(3, :s), HMC(0.4, 8, :m)),
                        Gibbs(HMC(0.1, 5, :s), ESS(:m)),
                    )
                else
                    (
                        HMC(0.1, 7),
                        IS(),
                        MH(),
                        Gibbs(HMC(0.1, 5, :s), ESS(:m)),
                    )
                end
                for sampler in samplers
                    Random.seed!(5)
                    chain1 = sample(model, sampler, MCMCThreads(), 1000, 4)

                    Random.seed!(5)
                    chain2 = sample(model, sampler, MCMCThreads(), 1000, 4)

                    @test chain1.value == chain2.value
                end
            end

            # Smoke test for default sample call.
            Random.seed!(100)
            chain = sample(gdemo_default, HMC(0.1, 7), MCMCThreads(), 1000, 4)
            check_gdemo(chain)

            # run sampler: progress logging should be disabled and
            # it should return a Chains object
            sampler = Sampler(HMC(0.1, 7), gdemo_default)
            chains = sample(gdemo_default, sampler, MCMCThreads(), 1000, 4)
            @test chains isa MCMCChains.Chains
        end
    end
    @testset "chain save/resume" begin
        Random.seed!(1234)

        alg1 = HMCDA(1000, 0.65, 0.15)
        alg2 = PG(20)
        alg3 = Gibbs(PG(30, :s), HMC(0.2, 4, :m))

        chn1 = sample(gdemo_default, alg1, 5000; save_state=true)
        check_gdemo(chn1)

        chn1_resumed = Turing.Inference.resume(chn1, 1000)
        check_gdemo(chn1_resumed)

        chn1_contd = sample(gdemo_default, alg1, 5000; resume_from=chn1)
        check_gdemo(chn1_contd)

        chn1_contd2 = sample(gdemo_default, alg1, 5000; resume_from=chn1, reuse_spl_n=1000)
        check_gdemo(chn1_contd2)

        chn2 = sample(gdemo_default, alg2, 1000; save_state=true)
        check_gdemo(chn2)

        chn2_contd = sample(gdemo_default, alg2, 1000; resume_from=chn2)
        check_gdemo(chn2_contd)

        chn3 = sample(gdemo_default, alg3, 5000; save_state=true)
        check_gdemo(chn3)

        chn3_contd = sample(gdemo_default, alg3, 1000; resume_from=chn3)
        check_gdemo(chn3_contd)
    end
    @testset "Contexts" begin
        # Test LikelihoodContext
        @model function testmodel1(x)
            a ~ Beta()
            lp1 = getlogp(__varinfo__)
            x[1] ~ Bernoulli(a)
            global loglike = getlogp(__varinfo__) - lp1
        end
        model = testmodel1([1.0])
        varinfo = Turing.VarInfo(model)
        model(varinfo, Turing.SampleFromPrior(), Turing.LikelihoodContext())
        @test getlogp(varinfo) == loglike

        # Test MiniBatchContext
        @model function testmodel2(x)
            a ~ Beta()
            x[1] ~ Bernoulli(a)
        end
        model = testmodel2([1.0])
        varinfo1 = Turing.VarInfo(model)
        varinfo2 = deepcopy(varinfo1)
        model(varinfo1, Turing.SampleFromPrior(), Turing.LikelihoodContext())
        model(varinfo2, Turing.SampleFromPrior(), Turing.MiniBatchContext(Turing.LikelihoodContext(), 10))
        @test isapprox(getlogp(varinfo2) / getlogp(varinfo1), 10)
    end
    @testset "Prior" begin
        N = 5000

        # Note that all chains contain 3 values per sample: 2 variables + log probability
        Random.seed!(100)
        chains = sample(gdemo_d(), Prior(), N)
        @test chains isa MCMCChains.Chains
        @test size(chains) == (N, 3, 1)
        @test mean(chains, :s) ≈ 3 atol=0.1
        @test mean(chains, :m) ≈ 0 atol=0.1

        Random.seed!(100)
        chains = sample(gdemo_d(), Prior(), MCMCThreads(), N, 4)
        @test chains isa MCMCChains.Chains
        @test size(chains) == (N, 3, 4)
        @test mean(chains, :s) ≈ 3 atol=0.1
        @test mean(chains, :m) ≈ 0 atol=0.1

        Random.seed!(100)
        chains = sample(gdemo_d(), Prior(), N; chain_type = Vector{NamedTuple})
        @test chains isa Vector{<:NamedTuple}
        @test length(chains) == N
        @test all(length(x) == 3 for x in chains)
        @test all(haskey(x, :lp) for x in chains)
        @test mean(x[:s][1] for x in chains) ≈ 3 atol=0.1
        @test mean(x[:m][1] for x in chains) ≈ 0 atol=0.1
    end

    @testset "chain ordering" begin
        for alg in (Prior(), Emcee(10, 2.0))
            chain_sorted = sample(gdemo_default, alg, 1, sort_chain=true)
            @test names(MCMCChains.get_sections(chain_sorted, :parameters)) == [:m, :s]

            chain_unsorted = sample(gdemo_default, alg, 1, sort_chain=false)
            @test names(MCMCChains.get_sections(chain_unsorted, :parameters)) == [:s, :m]
        end
    end

    @testset "chain iteration numbers" begin
        for alg in (Prior(), Emcee(10, 2.0))
            chain = sample(gdemo_default, alg, 10)
            @test range(chain) == 1:10

            chain = sample(gdemo_default, alg, 10; discard_initial=5, thinning=2)
            @test range(chain) == range(6; step=2, length=10)
        end
    end
end
