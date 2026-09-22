// Does libbmv2 support one bm::Switch instance per thread, running concurrently?
//
// This mirrors the Days execution model: nexosim requires `Model: Send + !Sync`,
// so a switch actor may move between worker threads but is never touched by two
// threads at once. The question is whether libbmv2 tolerates that.
//
// The harness deliberately contains no shared mutable state of its own, so any
// race reported by ThreadSanitizer belongs to libbmv2.

#include <bm/bm_sim/actions.h>
#include <bm/bm_sim/deparser.h>
#include <bm/bm_sim/logger.h>
#include <fstream>
#include <sstream>
#include <bm/bm_sim/event_logger.h>
#include <bm/bm_sim/match_units.h>
#include <bm/bm_sim/packet.h>
#include <bm/bm_sim/parser.h>
#include <bm/bm_sim/phv.h>
#include <bm/bm_sim/P4Objects.h>
#include <bm/bm_sim/pipeline.h>
#include <bm/bm_sim/switch.h>

#include <atomic>
#include <condition_variable>
#include <deque>
#include <mutex>
#include <cstdint>
#include <cstring>
#include <iostream>
#include <map>
#include <memory>
#include <string>
#include <thread>
#include <vector>

namespace {

// v1model reserves 511 as the drop port.
constexpr int kDropPort = 511;
// bmv2 packet register 0 carries packet length, as in p4sim's RegisterAccess.
constexpr int kPacketLengthRegIdx = 0;

// ---- per-switch log routing --------------------------------------------
// bm::Logger is a process-global spdlog instance, so every switch writes to the
// same sink. Rather than swapping the global target per packet the way p4sim
// does (`use_logger_for_port`), we hand bmv2 one stream we own and demultiplex
// ourselves, which also lets us attach simulator context to every line.
//
// Single-threaded only, by construction: the "current switch" is global state.
// That is the intended debug mode; the multithreaded runs keep bmv2 logging off.
namespace p4log {

struct Context {
  int switch_id = -1;
  uint64_t packet_id = 0;
  uint64_t flow_id = 0;
  double sim_time = 0.0;
  /// Line number within the current packet. Sorting by
  /// (sim_time, switch_id, packet_id, seq) reproduces execution order exactly,
  /// every run, which wall-clock time cannot do — many events legitimately
  /// share a simulation timestamp, and that ordering must stay comparable
  /// against a reference implementation.
  uint64_t seq = 0;
};

// Which switch the calling thread is currently executing. Thread-local, so a
// worker pool can run several switches at once without them confusing each
// other's attribution.
thread_local Context g_ctx;

std::string g_dir;
std::mutex g_files_mu;
std::map<int, std::ofstream> g_files;

void write_line(int switch_id, const std::string &s) {
  std::lock_guard<std::mutex> lk(g_files_mu);
  auto it = g_files.find(switch_id);
  if (it == g_files.end()) {
    std::ostringstream p;
    p << g_dir << "/switch-" << switch_id << ".log";
    it = g_files.emplace(switch_id, std::ofstream(p.str())).first;
  }
  it->second << s;
}

// Accumulates bmv2 output a line at a time and writes it to the file of
// whichever switch is currently executing, prefixed with simulator context.
class TaggingBuf : public std::streambuf {
 public:
  int overflow(int c) override {
    if (c == EOF) return EOF;
    // The partial line is thread-local, so two threads logging at once cannot
    // interleave halves of each other's messages.
    thread_local std::string line;
    if (c == '\n') {
      if (!line.empty() && g_ctx.switch_id >= 0) {
        std::ostringstream o;
        o << "t=" << g_ctx.sim_time << " sw=" << g_ctx.switch_id
          << " flow=" << g_ctx.flow_id << " pkt=" << g_ctx.packet_id
          << " seq=" << g_ctx.seq++ << " | " << line << "\n";
        write_line(g_ctx.switch_id, o.str());
      }
      line.clear();
    } else {
      line.push_back(static_cast<char>(c));
    }
    return c;
  }
};

TaggingBuf g_buf;
std::ostream g_stream(&g_buf);

/// Call before running a packet's pipelines. Resets the per-packet line number.
void begin_packet(int switch_id, uint64_t flow_id, uint64_t packet_id,
                  double sim_time) {
  g_ctx.switch_id = switch_id;
  g_ctx.flow_id = flow_id;
  g_ctx.packet_id = packet_id;
  g_ctx.sim_time = sim_time;
  g_ctx.seq = 0;
}

void enable(const std::string &dir) {
  g_dir = dir;
  bm::Logger::set_logger_ostream(g_stream);
  bm::Logger::set_log_level(bm::Logger::LogLevel::TRACE);
}

void close() {
  for (auto &kv : g_files) kv.second.flush();
}

}  // namespace p4log

struct PacketResult {
  int egress_spec = -1;
  uint64_t digest = 0;   // FNV-1a over the deparsed bytes
  size_t out_len = 0;
};

uint64_t Fnv1a(const char *data, size_t len) {
  uint64_t h = 1469598103934665603ULL;
  for (size_t i = 0; i < len; i++) {
    h ^= static_cast<uint8_t>(data[i]);
    h *= 1099511628211ULL;
  }
  return h;
}

// A minimal single-context switch. bm::Switch has exactly two pure virtuals.
class TestSwitch : public bm::Switch {
 public:
  TestSwitch() : bm::Switch(false /* enable_swap */) {
    add_required_field("standard_metadata", "ingress_port");
    add_required_field("standard_metadata", "packet_length");
    add_required_field("standard_metadata", "instance_type");
    add_required_field("standard_metadata", "egress_spec");
    add_required_field("standard_metadata", "egress_port");
    force_arith_header("standard_metadata");
    // reading header fields back out needs arithmetic enabled on them
    force_arith_header("ethernet");
    force_arith_header("ipv4");
  }

  int receive_(bm::port_t, const char *, int) override { return 0; }
  void start_and_return_() override {}

  // Loads the compiled P4 JSON WITHOUT starting a Thrift server. This is the
  // in-process configuration path P4-Days needs; p4sim uses
  // init_from_options_parser() instead, which binds a TCP port per switch.
  bool Load(const std::string &json_path, bm::device_id_t device_id) {
    if (init_objects(json_path, device_id) != 0) return false;
    parser_ = get_parser("parser");
    ingress_ = get_pipeline("ingress");
    egress_ = get_pipeline("egress");
    deparser_ = get_deparser("deparser");
    return parser_ && ingress_ && egress_ && deparser_;
  }

  // Installs one ipv4_nhop entry: dst_ip -> (mac, port).
  bool AddRoute(uint32_t dst_ip, uint64_t mac, int port) {
    char key[4];
    for (int i = 0; i < 4; i++) key[i] = (dst_ip >> (24 - 8 * i)) & 0xff;
    std::vector<bm::MatchKeyParam> mk{
        {bm::MatchKeyParam::Type::EXACT, std::string(key, 4)}};

    char mac_bytes[6];
    for (int i = 0; i < 6; i++) mac_bytes[i] = (mac >> (40 - 8 * i)) & 0xff;
    bm::ActionData ad;
    ad.push_back_action_data(mac_bytes, 6);
    ad.push_back_action_data(static_cast<unsigned int>(port));

    bm::entry_handle_t handle;
    // simple_v1model uses ipv4_nhop/ipv4_forward(mac, port);
    // split_register uses ipv4_exact/forward(port) with no mac parameter.
    if (mt_add_entry(0, "MyIngress.ipv4_nhop", mk, "MyIngress.ipv4_forward",
                     std::move(ad), &handle) == bm::MatchErrorCode::SUCCESS) {
      return true;
    }
    bm::ActionData ad2;
    ad2.push_back_action_data(static_cast<unsigned int>(port));
    return mt_add_entry(0, "MyIngress.ipv4_exact", mk, "MyIngress.forward",
                        std::move(ad2),
                        &handle) == bm::MatchErrorCode::SUCCESS;
  }

  // --- split pipeline: the two halves may run on different threads, as they
  // would in Days (P4Switch actor does ingress, Port actor does egress after
  // the queue). Both halves touch this same bm::Switch instance.
  std::unique_ptr<bm::Packet> ProcessIngress(const std::vector<uint8_t> &frame,
                                             int ingress_port) {
    const int len = static_cast<int>(frame.size());
    auto pkt = new_packet_ptr(
        ingress_port, packet_id_++, len,
        bm::PacketBuffer(len + 512,
                         reinterpret_cast<const char *>(frame.data()), len));

    bm::PHV *phv = pkt->get_phv();
    phv->reset_metadata();
    phv->get_field("standard_metadata.ingress_port").set(ingress_port);
    phv->get_field("standard_metadata.packet_length").set(len);
    phv->get_field("standard_metadata.instance_type").set(0);
    pkt->set_register(kPacketLengthRegIdx, len);

    parser_->parse(pkt.get());
    ingress_->apply(pkt.get());
    return pkt;
  }

  PacketResult ProcessEgress(std::unique_ptr<bm::Packet> pkt) {
    bm::PHV *phv = pkt->get_phv();
    PacketResult r;
    r.egress_spec = phv->get_field("standard_metadata.egress_spec").get_int();
    if (r.egress_spec == kDropPort) return r;

    phv->get_field("standard_metadata.egress_port").set(r.egress_spec);
    egress_->apply(pkt.get());
    deparser_->deparse(pkt.get());

    r.out_len = pkt->get_data_size();
    r.digest = Fnv1a(pkt->data(), r.out_len);
    return r;
  }

  // reads a register cell, so the test can check what the two pipelines did
  uint64_t ReadRegister(const std::string &name, size_t idx) {
    bm::Data d;
    if (register_read(0, name, idx, &d) != bm::Register::RegisterErrorCode::SUCCESS) {
      return UINT64_MAX;
    }
    return d.get_uint64();
  }

  PacketResult Process(const std::vector<uint8_t> &frame, int ingress_port) {
    const int len = static_cast<int>(frame.size());
    auto pkt = new_packet_ptr(
        ingress_port, packet_id_++, len,
        bm::PacketBuffer(len + 512,
                         reinterpret_cast<const char *>(frame.data()), len));

    bm::PHV *phv = pkt->get_phv();
    phv->reset_metadata();
    phv->get_field("standard_metadata.ingress_port").set(ingress_port);
    phv->get_field("standard_metadata.packet_length").set(len);
    phv->get_field("standard_metadata.instance_type").set(0);
    pkt->set_register(kPacketLengthRegIdx, len);

    parser_->parse(pkt.get());
    ingress_->apply(pkt.get());

    PacketResult r;
    r.egress_spec = phv->get_field("standard_metadata.egress_spec").get_int();
    if (r.egress_spec == kDropPort) return r;   // dropped, no egress/deparse

    phv->get_field("standard_metadata.egress_port").set(r.egress_spec);
    egress_->apply(pkt.get());
    deparser_->deparse(pkt.get());

    r.out_len = pkt->get_data_size();
    r.digest = Fnv1a(pkt->data(), r.out_len);
    return r;
  }

 private:
  bm::Parser *parser_ = nullptr;
  bm::Pipeline *ingress_ = nullptr;
  bm::Pipeline *egress_ = nullptr;
  bm::Deparser *deparser_ = nullptr;
  uint64_t packet_id_ = 0;   // per instance, never shared
};

// Ethernet + IPv4, no options. TTL must be > 0 for ipv4_nhop to be applied.
std::vector<uint8_t> BuildFrame(uint32_t dst_ip, uint8_t ttl, size_t payload) {
  std::vector<uint8_t> f;
  const uint8_t eth[14] = {0x00, 0x00, 0x00, 0x00, 0x00, 0xaa,
                           0x00, 0x00, 0x00, 0x00, 0x00, 0xbb,
                           0x08, 0x00};
  f.insert(f.end(), eth, eth + 14);

  const uint16_t total_len = static_cast<uint16_t>(20 + payload);
  const uint8_t ip[20] = {
      0x45, 0x00,
      static_cast<uint8_t>(total_len >> 8), static_cast<uint8_t>(total_len),
      0x00, 0x01, 0x00, 0x00,
      ttl, 0x06, 0x00, 0x00,
      10, 0, 0, 1,
      static_cast<uint8_t>(dst_ip >> 24), static_cast<uint8_t>(dst_ip >> 16),
      static_cast<uint8_t>(dst_ip >> 8), static_cast<uint8_t>(dst_ip)};
  f.insert(f.end(), ip, ip + 20);
  f.resize(f.size() + payload, 0x41);
  return f;
}

std::vector<std::vector<uint8_t>> BuildWorkload(int count) {
  std::vector<std::vector<uint8_t>> w;
  w.reserve(count);
  for (int i = 0; i < count; i++) {
    // alternate between the two installed routes; vary size and TTL a little
    const uint32_t dst = (i % 2 == 0) ? 0x0a010101u : 0x0a010102u;
    w.push_back(BuildFrame(dst, static_cast<uint8_t>(32 + (i % 8)),
                           26 + (i % 17)));
  }
  return w;
}

bool Configure(TestSwitch *sw, const std::string &json, int device_id) {
  if (!sw->Load(json, device_id)) {
    std::cerr << "FAILED to load " << json << " (device " << device_id << ")\n";
    return false;
  }
  // Same two routes p4sim's flowtable_0.txt installs.
  if (!sw->AddRoute(0x0a010101u, 0x000000000001ULL, 0) ||
      !sw->AddRoute(0x0a010102u, 0x000000000003ULL, 1)) {
    std::cerr << "FAILED to install routes (device " << device_id << ")\n";
    return false;
  }
  return true;
}

void RunOne(TestSwitch *sw, const std::vector<std::vector<uint8_t>> &workload,
            std::vector<PacketResult> *out) {
  out->reserve(workload.size());
  for (const auto &f : workload) out->push_back(sw->Process(f, 0));
}

}  // namespace

int main(int argc, char **argv) {
  std::string json = "/home/tj/ns-3.39/contrib/p4sim/test/p4src/"
                     "simple_v1model/simple_v1model.json";
  bool warmup = true;
  std::string mode = "all";          // sequential | parallel | parallel-init | split | rust-headers | all
  int num_switches = 4;
  int num_packets = 1000;

  for (int i = 1; i < argc; i++) {
    std::string a = argv[i];
    if (a == "--json" && i + 1 < argc) json = argv[++i];
    else if (a == "--mode" && i + 1 < argc) mode = argv[++i];
    else if (a == "--switches" && i + 1 < argc) num_switches = std::stoi(argv[++i]);
    else if (a == "--packets" && i + 1 < argc) num_packets = std::stoi(argv[++i]);
    else if (a == "--no-warmup") warmup = false;
    else if (a == "--bmv2-log-split" && i + 1 < argc) {
      p4log::enable(argv[++i]);
    }
    else if (a == "--bmv2-log") {
      // bmv2's own textual logger, which is where a P4 program's log_msg()
      // output goes. Process-global: single-threaded debugging only.
      bm::Logger::set_logger_console();
      bm::Logger::set_log_level(bm::Logger::LogLevel::TRACE);
    }
  }

  std::cout << "json=" << json << "\nswitches=" << num_switches
            << " packets=" << num_packets << " mode=" << mode << "\n\n";

  // Force construction of libbmv2's lazily-initialized global EventLogger
  // singleton on the main thread, before any worker thread exists. Without
  // this, the first thread to call Parser::parse constructs it while other
  // threads read it. See README.md.
  if (warmup) {
    bm::EventLogger::get();
    std::cout << "warmup: EventLogger singleton forced on main thread\n\n";
  } else {
    std::cout << "warmup: DISABLED\n\n";
  }

  const auto workload = BuildWorkload(num_packets);

  // ---- stage 1: sequential reference -------------------------------------
  std::vector<std::vector<PacketResult>> seq(num_switches);
  if (mode == "sequential" || mode == "all") {
    std::vector<std::unique_ptr<TestSwitch>> sws;
    for (int i = 0; i < num_switches; i++) {
      sws.push_back(std::make_unique<TestSwitch>());
      if (!Configure(sws.back().get(), json, i)) return 2;
    }
    for (int i = 0; i < num_switches; i++) {
      for (size_t k = 0; k < workload.size(); k++) {
        p4log::begin_packet(i, k % 2, k, 0.001 * static_cast<double>(k));
        seq[i].push_back(sws[i]->Process(workload[k], 0));
      }
    }
    p4log::close();

    // dump any shared_counters cells so a probe program can report what the
    // packet-creating primitives actually did
    {
      const uint64_t c0 = sws[0]->ReadRegister("shared_counters", 0);
      if (c0 != UINT64_MAX) {
        std::cout << "[registers] switch 0 shared_counters[0..2] = "
                  << c0 << ", " << sws[0]->ReadRegister("shared_counters", 1)
                  << ", " << sws[0]->ReadRegister("shared_counters", 2)
                  << "   (packets=" << workload.size() << ")\n";
      }
    }

    std::cout << "[sequential] ok\n";
    for (int i = 0; i < num_switches; i++) {
      std::cout << "  switch " << i << ": first egress_spec="
                << seq[i][0].egress_spec << " digest=" << std::hex
                << seq[i][0].digest << std::dec
                << " out_len=" << seq[i][0].out_len << "\n";
    }
    std::cout << "\n";
  }

  // ---- stage 2: parallel, init on main thread ----------------------------
  // Separates steady-state races from initialization races.
  if (mode == "parallel" || mode == "all") {
    std::vector<std::unique_ptr<TestSwitch>> sws;
    for (int i = 0; i < num_switches; i++) {
      sws.push_back(std::make_unique<TestSwitch>());
      if (!Configure(sws.back().get(), json, i)) return 2;
    }

    std::vector<std::vector<PacketResult>> par(num_switches);
    std::vector<std::thread> threads;
    for (int i = 0; i < num_switches; i++) {
      threads.emplace_back([&, i] {
        for (size_t k = 0; k < workload.size(); k++) {
          p4log::begin_packet(i, k % 2, k, 0.001 * static_cast<double>(k));
          par[i].push_back(sws[i]->Process(workload[k], 0));
        }
      });
    }
    for (auto &t : threads) t.join();
    std::cout << "[parallel] ok (init on main thread)\n";

    if (mode == "all") {
      size_t mismatches = 0;
      for (int i = 0; i < num_switches; i++) {
        for (size_t k = 0; k < workload.size(); k++) {
          if (par[i][k].egress_spec != seq[i][k].egress_spec ||
              par[i][k].digest != seq[i][k].digest) {
            if (mismatches < 5) {
              std::cout << "  MISMATCH switch " << i << " packet " << k
                        << ": seq(" << seq[i][k].egress_spec << ","
                        << std::hex << seq[i][k].digest << std::dec
                        << ") par(" << par[i][k].egress_spec << ","
                        << std::hex << par[i][k].digest << std::dec << ")\n";
            }
            mismatches++;
          }
        }
      }
      std::cout << "[equivalence] " << (mismatches ? "FAIL" : "PASS") << " — "
                << mismatches << " mismatching packets out of "
                << (size_t)num_switches * workload.size() << "\n";
      if (mismatches) return 1;
    }
    std::cout << "\n";
  }

  // ---- stage 2b: parallel, init inside the threads ------------------------
  if (mode == "parallel-init" || mode == "all") {
    std::vector<std::unique_ptr<TestSwitch>> sws(num_switches);
    std::atomic<int> failures{0};
    std::vector<std::thread> threads;
    for (int i = 0; i < num_switches; i++) {
      threads.emplace_back([&, i] {
        sws[i] = std::make_unique<TestSwitch>();
        if (!Configure(sws[i].get(), json, i)) { failures++; return; }
        std::vector<PacketResult> r;
        RunOne(sws[i].get(), workload, &r);
      });
    }
    for (auto &t : threads) t.join();
    if (failures) {
      std::cout << "[parallel-init] FAILED (" << failures << " switches)\n";
      return 3;
    }
    std::cout << "[parallel-init] ok (construction + init inside threads)\n";
  }

  // ---- stage 2c: parse headers synthesized by the Rust side ---------------
  // Validates the boundary the Rust unit tests cannot reach: bytes Days builds
  // must satisfy a real P4 parser, and the fields must arrive intact.
  if (mode == "rust-headers") {
    const char *path = std::getenv("P4_HEADERS_IN");
    if (!path) {
      std::cerr << "set P4_HEADERS_IN to the file produced by the Rust test\n";
      return 2;
    }
    std::ifstream in(path);
    if (!in) { std::cerr << "cannot open " << path << "\n"; return 2; }

    TestSwitch sw;
    if (!Configure(&sw, json, 0)) return 2;

    std::string src, dst, size, prio, ecn, hex;
    size_t n = 0, bad = 0;
    while (in >> src >> dst >> size >> prio >> ecn >> hex) {
      std::vector<uint8_t> frame;
      for (size_t i = 0; i + 1 < hex.size(); i += 2) {
        frame.push_back(static_cast<uint8_t>(std::stoul(hex.substr(i, 2), nullptr, 16)));
      }
      auto pkt = sw.ProcessIngress(frame, 0);
      bm::PHV *phv = pkt->get_phv();

      const bool ipv4_ok = phv->has_header("ipv4") && phv->get_header("ipv4").is_valid();
      uint64_t ttl = 0, tos = 0, dst_ip = 0, total_len = 0;
      if (ipv4_ok) {
        ttl = phv->get_field("ipv4.ttl").get_uint64();
        tos = phv->get_field("ipv4.diffserv").get_uint64();
        dst_ip = phv->get_field("ipv4.dstAddr").get_uint64();
        total_len = phv->get_field("ipv4.totalLen").get_uint64();
      }
      std::cout << "  src=" << src << " dst=" << dst << " size=" << size
                << " prio=" << prio << " ecn=" << ecn
                << "  ->  ipv4_valid=" << (ipv4_ok ? "yes" : "NO")
                << " ttl=" << ttl << " tos=0x" << std::hex << tos << std::dec
                << " totalLen=" << total_len
                << " dstAddr=0x" << std::hex << dst_ip << std::dec << "\n";
      if (!ipv4_ok) bad++;
      n++;
    }
    std::cout << "[rust-headers] " << (bad ? "FAIL" : "PASS") << " — " << n
              << " headers, " << bad << " unparsed\n";
    return bad ? 1 : 0;
  }

  // ---- stage 3: ingress and egress on DIFFERENT threads, ONE switch --------
  // This is the deferred pipeline-split question: in Days, ingress runs in the
  // P4Switch actor and egress runs later, from the Port actor, after the Days
  // scheduler's queue. Two actors, two threads, but they must share the one
  // bm::Switch that holds the tables and registers.
  if (mode == "split" || mode == "all") {
    TestSwitch sw;
    if (!Configure(&sw, json, 0)) return 2;

    // hand-off queue between the two stages; this synchronisation is ours and
    // is deliberately correct, so any race Helgrind reports belongs to libbmv2
    std::mutex m;
    std::condition_variable cv;
    std::deque<std::unique_ptr<bm::Packet>> handoff;
    bool ingress_done = false;

    std::vector<PacketResult> split_results;
    split_results.reserve(workload.size());

    std::thread ingress_thread([&] {
      for (const auto &f : workload) {
        auto pkt = sw.ProcessIngress(f, 0);
        {
          std::lock_guard<std::mutex> lk(m);
          handoff.push_back(std::move(pkt));
        }
        cv.notify_one();
      }
      {
        std::lock_guard<std::mutex> lk(m);
        ingress_done = true;
      }
      cv.notify_one();
    });

    std::thread egress_thread([&] {
      for (;;) {
        std::unique_ptr<bm::Packet> pkt;
        {
          std::unique_lock<std::mutex> lk(m);
          cv.wait(lk, [&] { return !handoff.empty() || ingress_done; });
          if (handoff.empty()) {
            if (ingress_done) break;
            continue;
          }
          pkt = std::move(handoff.front());
          handoff.pop_front();
        }
        split_results.push_back(sw.ProcessEgress(std::move(pkt)));
      }
    });

    ingress_thread.join();
    egress_thread.join();

    // Lost-update check. Every packet increments shared_counters[0] once in
    // ingress and once in egress, and shared_counters[1] once in egress. If the
    // two threads race on the register array, increments go missing.
    const uint64_t r0 = sw.ReadRegister("shared_counters", 0);
    const uint64_t r1 = sw.ReadRegister("shared_counters", 1);
    if (r0 != UINT64_MAX) {
      const uint64_t expect0 = 2 * workload.size();
      const uint64_t expect1 = workload.size();
      std::cout << "[split registers] shared_counters[0]=" << r0
                << " (expect " << expect0 << "), [1]=" << r1
                << " (expect " << expect1 << ")  "
                << ((r0 == expect0 && r1 == expect1) ? "PASS" : "LOST UPDATES")
                << "\n";
      if (r0 != expect0 || r1 != expect1) return 4;
    } else {
      std::cout << "[split registers] program has no 'shared_counters' array\n";
    }

    std::cout << "[split] ok — " << split_results.size()
              << " packets through ingress(thread A) -> egress(thread B), "
              << "one shared bm::Switch\n";

    // compare against a single-threaded run of the same split
    TestSwitch ref;
    if (!Configure(&ref, json, 1)) return 2;
    size_t mismatches = 0;
    for (size_t k = 0; k < workload.size(); k++) {
      auto pkt = ref.ProcessIngress(workload[k], 0);
      auto r = ref.ProcessEgress(std::move(pkt));
      if (k < split_results.size() &&
          (r.egress_spec != split_results[k].egress_spec ||
           r.digest != split_results[k].digest)) {
        if (mismatches < 5) {
          std::cout << "  MISMATCH packet " << k << "\n";
        }
        mismatches++;
      }
    }
    std::cout << "[split equivalence] " << (mismatches ? "FAIL" : "PASS")
              << " — " << mismatches << " mismatching packets\n";
    if (mismatches) return 1;
    std::cout << "\n";
  }

  std::cout << "\nDONE\n";
  return 0;
}
