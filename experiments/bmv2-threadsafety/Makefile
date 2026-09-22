CXX      ?= g++
CXXFLAGS := -std=c++17 -I/usr/local/include -Wall -Wextra -Wno-unused-parameter
# The v1model primitives (register_read/write, mark_to_drop, hash, ...) live in
# the simple_switch target, not in bm::Switch. Linking registers them through
# static initialization; SimpleSwitchRunner::init_and_start() is never called,
# so no Thrift server and no bmv2-owned threads. See README.md.
LDFLAGS  := -L/usr/local/lib -Wl,--no-as-needed \
            -lsimpleswitch_runner -lsimpleswitch_thrift \
            -lbmall -lgmp -lpthread
RPATH    := -Wl,-rpath,/usr/local/lib

all: harness

harness: harness.cc
	$(CXX) $(CXXFLAGS) -O2 -g $< -o $@ $(LDFLAGS) $(RPATH)

harness-tsan: harness.cc
	$(CXX) $(CXXFLAGS) -fsanitize=thread -O1 -g $< -o $@ $(LDFLAGS) $(RPATH)

tsan: harness-tsan

P4JSON ?= ../../p4-programs/split_register/split_register.json

run: harness
	./harness --mode all --json $(P4JSON)

run-tsan: harness-tsan
	TSAN_OPTIONS="history_size=7" setarch $$(uname -m) -R ./harness-tsan --mode parallel --json $(P4JSON)

run-split: harness
	valgrind --tool=helgrind --log-file=results/helgrind-split-registers.log \
	  ./harness --mode split --json $(P4JSON) --packets 40

clean:
	rm -f harness harness-tsan harness-ss

.PHONY: all tsan run run-tsan run-split clean
