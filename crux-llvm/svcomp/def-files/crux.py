# This file is part of BenchExec, a framework for reliable benchmarking:
# https://github.com/sosy-lab/benchexec
#
# SPDX-FileCopyrightText: 2007-2020 Dirk Beyer <https://www.sosy-lab.org>
#
# SPDX-License-Identifier: Apache-2.0

import benchexec.tools.template
import benchexec.result as result
from benchexec.tools.sv_benchmarks_util import get_data_model_from_task, ILP32, LP64


class Tool(benchexec.tools.template.BaseTool2):
    """
    Tool info for Crux (https://crux.galois.com/).
    """

    def executable(self, tool_locator):
        return tool_locator.find_executable("crux-llvm-svcomp-driver.sh")

    def name(self):
        return "Crux"

    def cmdline(self, executable, options, task, rlimits):
        if task.property_file:
            options += ["--svcomp-spec", task.property_file]
        data_model_param = get_data_model_from_task(
            task, {ILP32: "32bit", LP64: "64bit"}
        )
        if data_model_param:
            options += ["--svcomp-arch", data_model_param]
        # TODO: Move this to crux.xml
        options += ["--config", "unreach-call.config"]
        return [executable] + options + list(task.input_files_or_identifier)

    def version(self, executable):
        s = self._version_from_tool(executable)
        return s[s.find("version:"):]

    def determine_result(self, run):
        for line in run.output:
            if "Verification result: VERIFIED" in line:
                return result.RESULT_TRUE_PROP
            elif "Verification result: FALSIFIED (valid-free)" in line:
                return result.RESULT_FALSE_FREE
            elif "Verification result: FALSIFIED (valid-deref)" in line:
                return result.RESULT_FALSE_DEREF
            elif "Verification result: FALSIFIED (valid-memtrack)" in line:
                return result.RESULT_FALSE_MEMTRACK
            elif "Verification result: FALSIFIED (valid-memcleanup)" in line:
                return result.RESULT_FALSE_MEMCLEANUP
            elif "Verification result: FALSIFIED (no-overflow)" in line:
                return result.RESULT_FALSE_OVERFLOW
            elif "Verification result: FALSIFIED (termination)" in line:
                return result.RESULT_FALSE_TERMINATION
            elif "Verification result: FALSIFIED (unreach-call)" in line:
                return result.RESULT_FALSE_REACH
            elif "Verification result: FALSIFIED" in line:
                return result.RESULT_FALSE_PROP
            elif "Verification result: UNKNOWN" in line:
                return result.RESULT_UNKNOWN + "(incomplete)"
            elif "Verification result: ERROR" in line:
                return result.RESULT_ERROR
        return result.RESULT_UNKNOWN

    def program_files(self, executable):
        return [executable] + self.REQUIRED_PATHS
