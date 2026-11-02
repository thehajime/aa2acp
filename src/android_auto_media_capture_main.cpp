#include "aa2acp/aa/wired_receiver.hpp"
#include "aa2acp/bridge/h264_normalizer.hpp"
#include "aa2acp/bridge/logging.hpp"

#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>

#include <atomic>
#include <cerrno>
#include <csignal>
#include <cstdint>
#include <filesystem>
#include <iostream>
#include <span>
#include <string>

namespace {
volatile std::sig_atomic_t stopping = 0;
void stop(int) { stopping = 1; }

bool write_all(int fd, std::span<const std::uint8_t> data) {
  while (!data.empty()) {
    const auto count = write(fd, data.data(), data.size());
    if (count < 0 && errno == EINTR)
      continue;
    if (count <= 0)
      return false;
    data = data.subspan(static_cast<std::size_t>(count));
  }
  return true;
}

bool write_capped(int fd, std::span<const std::uint8_t> data,
                  std::uint64_t &written, std::uint64_t limit) {
  if (data.size() > limit - written || !write_all(fd, data))
    return false;
  written += data.size();
  return true;
}

int capture_file(const std::filesystem::path &path) {
  return open(path.c_str(),
              O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
              S_IRUSR | S_IWUSR);
}
} // namespace

int main(int argc, char **argv) {
  if (argc != 2) {
    aa2acp::bridge::log(aa2acp::bridge::LogLevel::error)
        << "usage: aa2acp-media-capture OUTPUT_DIRECTORY\n";
    return 2;
  }
  const std::filesystem::path directory(argv[1]);
  std::error_code error;
  if (!std::filesystem::create_directory(directory, error) || error ||
      chmod(directory.c_str(), S_IRWXU) != 0) {
    aa2acp::bridge::log(aa2acp::bridge::LogLevel::error)
        << "output directory must be new and writable\n";
    return 2;
  }
  const int video = capture_file(directory / "video.h264");
  const int guidance = capture_file(directory / "guidance.s16le");
  if (video < 0 || guidance < 0) {
    aa2acp::bridge::log(aa2acp::bridge::LogLevel::error)
        << "unable to create owner-only capture files\n";
    if (video >= 0)
      close(video);
    if (guidance >= 0)
      close(guidance);
    return 2;
  }
  std::signal(SIGINT, stop);
  std::signal(SIGTERM, stop);
  aa2acp::bridge::H264Normalizer normalizer;
  std::atomic_bool write_failed{};
  std::uint64_t video_written = 0;
  std::uint64_t guidance_written = 0;
  constexpr std::uint64_t video_limit = 64 * 1024 * 1024;
  constexpr std::uint64_t guidance_limit = 16 * 1024 * 1024;
  aa2acp::aa::WiredReceiver receiver(
      [](const auto &event) {
        aa2acp::bridge::log(aa2acp::bridge::LogLevel::info)
            << "Android Auto event " << static_cast<int>(event.type) << ": "
            << event.detail << '\n';
      },
      [&](std::span<const std::uint8_t> frame) {
        std::string normalize_error;
        for (const auto &unit : normalizer.normalize(frame, &normalize_error))
          if (!write_capped(video, unit, video_written, video_limit))
            write_failed = true;
      },
      [&](aa2acp::aa::AudioStream stream, std::span<const std::uint8_t> pcm) {
        if (stream == aa2acp::aa::AudioStream::guidance &&
            !write_capped(guidance, pcm, guidance_written, guidance_limit))
          write_failed = true;
      },
      []() -> std::optional<aa2acp::aa::HeadUnitCapabilities> {
        return aa2acp::aa::HeadUnitCapabilities{1280, 720,  30,
                                                true, true, true};
      });
  std::string start_error;
  if (!receiver.start(&start_error)) {
    aa2acp::bridge::log(aa2acp::bridge::LogLevel::error)
        << "USB receiver: " << start_error << '\n';
    close(video);
    close(guidance);
    return 1;
  }
  while (!stopping && !write_failed)
    usleep(100000);
  receiver.stop();
  close(video);
  close(guidance);
  return write_failed ? 1 : 0;
}
