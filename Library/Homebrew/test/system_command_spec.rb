# frozen_string_literal: true

describe SystemCommand do
  describe "#initialize" do
    subject(:command) {
      described_class.new(
        "env",
        args:         env_args,
        env:          env,
        must_succeed: true,
        sudo:         sudo,
      )
    }

    let(:env_args) { ["bash", "-c", 'printf "%s" "${A?}" "${B?}" "${C?}"'] }
    let(:env) { { "A" => "1", "B" => "2", "C" => "3" } }
    let(:sudo) { false }

    context "when given some environment variables" do
      its("run!.stdout") { is_expected.to eq("123") }

      describe "the resulting command line" do
        it "includes the given variables explicitly" do
          expect(Open3)
            .to receive(:popen3)
            .with(an_instance_of(Hash), ["/usr/bin/env", "/usr/bin/env"], "A=1", "B=2", "C=3", "env", *env_args, {})
            .and_call_original

          command.run!
        end
      end
    end

    context "when given an environment variable which is set to nil" do
      let(:env) { { "A" => "1", "B" => "2", "C" => nil } }

      it "unsets them" do
        expect {
          command.run!
        }.to raise_error(/C: parameter null or not set/)
      end
    end

    context "when given some environment variables and sudo: true" do
      let(:sudo) { true }

      describe "the resulting command line" do
        it "includes the given variables explicitly" do
          expect(Open3)
            .to receive(:popen3)
            .with(an_instance_of(Hash), ["/usr/bin/sudo", "/usr/bin/sudo"], "-E", "--",
                  "/usr/bin/env", "A=1", "B=2", "C=3", "env", *env_args, {})
            .and_wrap_original do |original_popen3, *_, &block|
              original_popen3.call("true", &block)
            end

          command.run!
        end
      end
    end
  end

  context "when the exit code is 0" do
    describe "its result" do
      subject { described_class.run("true") }

      it { is_expected.to be_a_success }
      its(:exit_status) { is_expected.to eq(0) }
    end
  end

  context "when the exit code is 1" do
    let(:command) { "false" }

    context "and the command must succeed" do
      it "throws an error" do
        expect {
          described_class.run!(command)
        }.to raise_error(ErrorDuringExecution)
      end
    end

    context "and the command does not have to succeed" do
      describe "its result" do
        subject { described_class.run(command) }

        it { is_expected.not_to be_a_success }
        its(:exit_status) { is_expected.to eq(1) }
      end
    end
  end

  context "when given a pathname" do
    let(:command) { "/bin/ls" }
    let(:path)    { Pathname(Dir.mktmpdir) }

    before do
      FileUtils.touch(path.join("somefile"))
    end

    describe "its result" do
      subject { described_class.run(command, args: [path]) }

      it { is_expected.to be_a_success }
      its(:stdout) { is_expected.to eq("somefile\n") }
    end
  end

  context "with both STDOUT and STDERR output from upstream" do
    let(:command) { "/bin/bash" }
    let(:options) {
      { args: [
        "-c",
        "for i in $(seq 1 2 5); do echo $i; echo $(($i + 1)) >&2; done",
      ] }
    }

    shared_examples "it returns '1 2 3 4 5 6'" do
      describe "its result" do
        subject { described_class.run(command, options) }

        it { is_expected.to be_a_success }
        its(:stdout) { is_expected.to eq([1, 3, 5, nil].join("\n")) }
        its(:stderr) { is_expected.to eq([2, 4, 6, nil].join("\n")) }
      end
    end

    context "with default options" do
      it "echoes only STDERR" do
        expected = [2, 4, 6].map { |i| "#{i}\n" }.join
        expect {
          described_class.run(command, options)
        }.to output(expected).to_stderr
      end

      include_examples("it returns '1 2 3 4 5 6'")
    end

    context "with print_stdout" do
      before do
        options.merge!(print_stdout: true)
      end

      it "echoes both STDOUT and STDERR" do
        expect { described_class.run(command, options) }
          .to output("1\n3\n5\n").to_stdout
          .and output("2\n4\n6\n").to_stderr
      end

      include_examples("it returns '1 2 3 4 5 6'")
    end

    context "without print_stderr" do
      before do
        options.merge!(print_stderr: false)
      end

      it "echoes nothing" do
        expect {
          described_class.run(command, options)
        }.to output("").to_stdout
      end

      include_examples("it returns '1 2 3 4 5 6'")
    end

    context "with print_stdout but without print_stderr" do
      before do
        options.merge!(print_stdout: true, print_stderr: false)
      end

      it "echoes only STDOUT" do
        expected = [1, 3, 5].map { |i| "#{i}\n" }.join
        expect {
          described_class.run(command, options)
        }.to output(expected).to_stdout
      end

      include_examples("it returns '1 2 3 4 5 6'")
    end
  end

  context "with a very long STDERR output" do
    let(:command) { "/bin/bash" }
    let(:options) {
      { args: [
        "-c",
        "for i in $(seq 1 2 100000); do echo $i; echo $(($i + 1)) >&2; done",
      ] }
    }

    it "returns without deadlocking" do
      wait(30).for {
        described_class.run(command, options)
      }.to be_a_success
    end
  end

  context "when given an invalid variable name" do
    it "raises an ArgumentError" do
      expect { described_class.run("true", env: { "1ABC" => true }) }
        .to raise_error(ArgumentError, /variable name/)
    end
  end

  it "looks for executables in a custom PATH" do
    mktmpdir do |path|
      (path/"tool").write <<~SH
        #!/bin/sh
        echo Hello, world!
      SH

      FileUtils.chmod "+x", path/"tool"

      expect(described_class.run("tool", env: { "PATH" => path }).stdout).to include "Hello, world!"
    end
  end

  describe "#run" do
    it "does not raise a `SystemCallError` when the executable does not exist" do
      expect {
        described_class.run("non_existent_executable")
      }.not_to raise_error
    end

    it 'does not format `stderr` when it starts with \r' do
      expect {
        system_command \
          "bash",
          args: [
            "-c",
            'printf "\r%s" "###################                                                       27.6%" 1>&2',
          ]
      }.to output( \
        "\r###################                                                       27.6%",
      ).to_stderr
    end

    context "when given an executable with spaces and no arguments" do
      let(:executable) { mktmpdir/"App Uninstaller" }

      before do
        executable.write <<~SH
          #!/usr/bin/env bash
          true
        SH

        FileUtils.chmod "+x", executable
      end

      it "does not interpret the executable as a shell line" do
        expect(system_command(executable)).to be_a_success
      end
    end

    context "when given arguments with secrets" do
      it "does not leak the secrets" do
        redacted_msg = /#{Regexp.escape("username:******")}/
        expect do
          described_class.run! "curl",
                               args:    %w[--user username:hunter2],
                               verbose: true,
                               secrets: %w[hunter2]
        end.to raise_error.with_message(redacted_msg).and output(redacted_msg).to_stdout
      end

      it "does not leak the secrets set by environment" do
        redacted_msg = /#{Regexp.escape("username:******")}/
        expect do
          begin
            ENV["PASSWORD"] = "hunter2"
            described_class.run! "curl",
                                 args:    %w[--user username:hunter2],
                                 verbose: true
          ensure
            ENV.delete "PASSWORD"
          end
        end.to raise_error.with_message(redacted_msg).and output(redacted_msg).to_stdout
      end
    end
  end
end
