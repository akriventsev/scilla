# Invoke `make` to build, `make clean` to clean up, etc.

OCAML_VERSION_RECOMMENDED=4.12.0
# In case of upgrading ocamlformat version:
# package.json also needs updating
OCAMLFORMAT_VERSION=0.22.4
IPC_SOCK_PATH="/tmp/zilliqa.sock"
CPPLIB_DIR=${PWD}/_build/default/src/base/cpp
VCPKG_BASE=${PWD}/vcpkg_installed/$(shell scripts/vcpkg_triplet.sh)

# Dependencies useful for developing Scilla
OPAM_DEV_DEPS := \
merlin \
ocamlformat.$(OCAMLFORMAT_VERSION) \
ocp-indent \
utop

# Determine the rpath patch tool based on the OS
OS_NAME := $(shell uname -s)
ifeq ($(OS_NAME),Linux)
	RPATH_CMD := patchelf --set-rpath
endif
ifeq ($(OS_NAME),Darwin)
	RPATH_CMD := install_name_tool -add_rpath
endif

define patch_rpath
	find _build/default/$(1) -type f -name '*.exe' -exec chmod u+w \{} \; -exec $(RPATH_CMD) "$(VCPKG_BASE)/lib" \{} \; -exec chmod u+w \{} \;
endef

.PHONY: default release utop dev clean docker zilliqa-docker

default: release

# Build one library and one standalone executable that implements
# multiple subcommands and uses the library.
# The library can be loaded in utop for interactive testing.
release:
	./scripts/build_deps.sh
	dune build --profile release @install
	$(call patch_rpath,src/runners)
	@test -L bin || ln -s _build/install/default/bin .

# Build only scilla-checker and scilla-runner
slim:
	./scripts/build_deps.sh
	dune build --profile release src/runners/scilla_runner.exe
	dune build --profile release src/runners/scilla_checker.exe
	$(call patch_rpath,src/runners)
	@test -L bin || ln -s _build/install/default/bin .

dev:
	./scripts/build_deps.sh
	dune build --profile dev @install
	dune build --profile dev tests/scilla_client.exe
	$(call patch_rpath,src/runners)
	@test -L bin || ln -s _build/install/default/bin .
	ln -s ../../../default/tests/scilla_client.exe _build/install/default/bin/scilla-client

# Update src/base/ParserFaults.messages
parser-messages:
	menhir --list-errors src/base/ScillaParser.mly >src/base/NewParserFaultsStubs.messages
	menhir --merge-errors src/base/ParserFaults.messages \
		   --merge-errors src/base/NewParserFaultsStubs.messages \
		   src/base/ScillaParser.mly  >src/base/NewParserFaults.messages
	mv src/base/NewParserFaults.messages src/base/ParserFaults.messages
	rm src/base/NewParserFaultsStubs.messages

# Launch utop such that it finds the libraries.
utop: release
	OCAMLPATH=_build/install/default/lib:$(OCAMLPATH) utop

fmt:
	dune build @fmt --auto-promote

# Lint OCaml and dune source files, all the opam files in the project root, and the shell scripts
lint:
	dune build @fmt
	opam lint .
	shellcheck scripts/*.sh && shellcheck easyrun.sh && shellcheck tests/runner/pingpong.sh

# Installer, uninstaller and test the installation
install : release
	dune install

# This is different from the target "test" which runs on dev builds.
test_install : install
	dune build --profile release tests/polynomials/testsuite_polynomials.exe
	dune build --profile release tests/base/testsuite_base.exe
	dune build --profile release tests/testsuite.exe
	$(call patch_rpath,tests)
	ulimit -n 1024; dune exec --no-build -- tests/polynomials/testsuite_polynomials.exe
	ulimit -n 1024; dune exec --no-build -- tests/base/testsuite_base.exe -print-diff true
	ulimit -n 1024; dune exec --no-build -- tests/testsuite.exe -print-diff true

uninstall : release
	dune uninstall

# Debug with ocamldebug: Build byte code instead of native code.
debug :
	dune build --profile dev src/runners/scilla_runner.bc
	dune build --profile dev src/runners/scilla_checker.bc
	dune build --profile dev src/runners/type_checker.bc
	dune build --profile dev src/runners/eval_runner.bc
	@echo "Note: LD_LIBRARY_PATH must be set to ${CPPLIB_DIR} before execution"
	@echo "Example: LD_LIBRARY_PATH=${CPPLIB_DIR} ocamldebug _build/default/src/runners/scilla_checker.bc -libdir src/stdlib -gaslimit 10000 tests/contracts/helloworld.scilla"

# === TESTS (begin) ===========================================================
# Build and run tests

testbase: dev
  # This effectively adds all the runners into PATH variable
	dune build --profile dev tests/base/testsuite_base.exe
	$(call patch_rpath,tests)
	ulimit -n 1024; dune exec --no-build -- tests/base/testsuite_base.exe -print-diff true

goldbase: dev
	dune build --profile dev tests/base/testsuite_base.exe
	$(call patch_rpath,tests)
	ulimit -n 4096; dune exec --no-build -- tests/base/testsuite_base.exe -update-gold true

# Run all tests for all packages in the repo: scilla-base, polynomials, scilla
test: dev
	dune build --profile dev tests/polynomials/testsuite_polynomials.exe
	dune build --profile dev tests/base/testsuite_base.exe
	dune build --profile dev tests/testsuite.exe
	$(call patch_rpath,tests)
	ulimit -n 1024; dune exec --no-build -- tests/polynomials/testsuite_polynomials.exe
	ulimit -n 1024; dune exec --no-build -- tests/base/testsuite_base.exe -print-diff true
	ulimit -n 1024; dune exec --no-build -- tests/testsuite.exe -print-diff true
	dune runtest --force

gold: dev
	dune build --profile dev tests/base/testsuite_base.exe
	dune build --profile dev tests/testsuite.exe
	$(call patch_rpath,tests)
	ulimit -n 4096; dune exec --no-build -- tests/base/testsuite_base.exe -update-gold true
	ulimit -n 4096; dune exec --no-build -- tests/testsuite.exe -update-gold true
	dune promote

# This must be run only if there is an external IPC server available
# that can handle access requests. It is important to use the sequential runner here as we
# don't want multiple threads of the testsuite connecting to the same server concurrently.
test_extipcserver: dev
	dune build --profile dev tests/testsuite.exe
	$(call patch_rpath,tests)
	dune exec --no-build -- tests/testsuite.exe -print-diff true -runner sequential \
	-ext-ipc-server $(IPC_SOCK_PATH) \
	-only-test "tests:0:contract_tests:0:these_tests_must_SUCCEED"

# Run tests in server-mode
test_server: dev
	dune build src/runners/scilla_server.exe
	$(call patch_rpath,src/runners)
	dune build --profile dev tests/testsuite.exe
	$(call patch_rpath,tests)
	killall -r "scilla_server.exe" || true
	_build/default/src/runners/scilla_server.exe -daemonise -logs /tmp/scilla-server
	dune exec --no-build -- tests/testsuite.exe -print-diff true -runner sequential \
  -server true \
	-only-test "tests:0:contract_tests:0:these_tests_must_SUCCEED"
	killall -r "scilla_server.exe" || true

# === TESTS (end) =============================================================


# Clean up
clean:
# Remove files produced by dune.
	dune clean
# Remove remaining files/folders ignored by git as defined in .gitignore (-X)
# but keeping a local opam switch and other dependencies built.
	git clean -dfXq --exclude=\!deps/** --exclude=\!_opam/** --exclude=\!_esy/** --exclude=\!vcpkg_installed --exclude=\!vcpkg_installed/**

# Clean up libff installation
cleanall: clean
	rm -rf deps/cryptoutils/{build,install} deps/schnorr/{build,install} vcpkg_installed

# Build a standalone scilla docker
docker:
	DOCKER_BUILDKIT=1  docker buildx build --push --build-arg EXTRA_CMAKE_ARGS="$(cmake_extra_args)" --platform linux/arm64 -t ghcr.io/akriventsev/scilla:v0.13.3 . 

docker:
	docker buildx build --platform=linux/arm64 -t ghcr.io/akriventsev/scilla:v0.13.3 .


# Build a zilliqa-plus-scilla docker based on from zilliqa image ZILLIQA_IMAGE
zilliqa-docker:
	@if [ -z "$(ZILLIQA_IMAGE)" ]; \
	then \
		echo "ZILLIQA_IMAGE not specified" && \
		echo "Usage:\n\tmake zilliqa-docker ZILLIQA_IMAGE=zilliqa:zilliqa" && \
		echo "" && \
		exit 1; \
	fi
	docker build --build-arg BASE_IMAGE=$(ZILLIQA_IMAGE) .

# Create an opam-based development environment
.PHONY : opamdep
opamdep:
	opam init --compiler=ocaml-base-compiler.$(OCAML_VERSION_RECOMMENDED) --yes
	opam pin -n --yes ${PWD}/vcpkg-ocaml/vcpkg-secp256k1
	eval $$(opam env)
	opam install ./scilla.opam --deps-only --with-test --yes
	opam install --yes $(OPAM_DEV_DEPS)

.PHONY : dev-env
dev-deps:
	opam install --yes $(OPAM_DEV_DEPS)

.PHONY : opamdep-ci
opamdep-ci:
	opam init --disable-sandboxing --compiler=ocaml-base-compiler.$(OCAML_VERSION) --yes
	opam pin -n --yes ${PWD}/vcpkg-ocaml/vcpkg-secp256k1
	eval $$(opam env)
	opam install ./scilla.opam --deps-only --with-test --yes --assume-depexts
	opam install ocamlformat.$(OCAMLFORMAT_VERSION) --yes

.PHONY : coverage
coverage :
	make clean
	mkdir -p _build/coverage
	./scripts/build_deps.sh
	BISECT_ENABLE=YES make
	dune build @install
	ulimit -n 1024; dune exec -- tests/testsuite.exe
	bisect-ppx-report html -o ./coverage
	make clean
	-find . -type f -name 'bisect*.coverage' | xargs rm

.PHONY : coveralls
coveralls:
	make clean
	mkdir -p _build/coverage
	./scripts/build_deps.sh
	BISECT_ENABLE=YES make
	dune build @install
	ulimit -n 1024; dune exec -- tests/testsuite.exe
	bisect-ppx-report coveralls coverage.json --ignore-missing-files --service-name jenkins --service-job-id ${TRAVIS_JOB_ID}
	curl -L -F json_file=@./coverage.json https://coveralls.io/api/v1/jobs
	make clean
	-find . -type f -name 'bisect*.coverage' | xargs rm


# Diagnostic builds

verbose:
	dune build --profile dev @install --verbose

# sequential build
verbose-j1:
	dune build -j1 --profile dev @install --verbose
