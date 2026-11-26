package tmux

import (
	"bufio"
	"bytes"
	"context"
	"os"
	"os/exec"
	"path/filepath"
	"runtime"
	"strconv"
	"strings"
	"time"
)

// Process is one OS process as seen by ps.
type Process struct {
	PID  int
	PPID int
	Args string
	Name string // basename of argv[0]
}

// Processes snapshots the process table for this user.
func Processes(ctx context.Context) (map[int]Process, error) {
	ctx, cancel := context.WithTimeout(ctx, 5*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, "ps", "-axo", "pid=,ppid=,args=").Output()
	if err != nil {
		return nil, err
	}
	procs := map[int]Process{}
	sc := bufio.NewScanner(bytes.NewReader(out))
	for sc.Scan() {
		f := strings.Fields(sc.Text())
		if len(f) < 3 {
			continue
		}
		pid, err1 := strconv.Atoi(f[0])
		ppid, err2 := strconv.Atoi(f[1])
		if err1 != nil || err2 != nil {
			continue
		}
		args := strings.Join(f[2:], " ")
		procs[pid] = Process{PID: pid, PPID: ppid, Args: args, Name: filepath.Base(f[2])}
	}
	return procs, nil
}

// Descendants returns every process below root (breadth-first), excluding
// root. A root of zero or less has no descendants: pid 1's parent is 0, so
// walking from 0 would return the whole process table.
func Descendants(procs map[int]Process, root int) []Process {
	if root <= 0 {
		return nil
	}
	children := map[int][]int{}
	for pid, p := range procs {
		children[p.PPID] = append(children[p.PPID], pid)
	}
	var out []Process
	queue := []int{root}
	seen := map[int]bool{root: true}
	for len(queue) > 0 {
		cur := queue[0]
		queue = queue[1:]
		for _, ch := range children[cur] {
			if seen[ch] {
				continue
			}
			seen[ch] = true
			out = append(out, procs[ch])
			queue = append(queue, ch)
		}
	}
	return out
}

// Environ returns a process's environment (Linux: /proc; macOS: ps -E).
// Only the caller's own processes are readable, which is all we need.
func Environ(pid int) map[string]string {
	env := map[string]string{}
	if runtime.GOOS == "linux" {
		b, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/environ")
		if err != nil {
			return env
		}
		for _, kv := range bytes.Split(b, []byte{0}) {
			if i := bytes.IndexByte(kv, '='); i > 0 {
				env[string(kv[:i])] = string(kv[i+1:])
			}
		}
		return env
	}
	if runtime.GOOS == "darwin" {
		out, err := exec.Command("ps", "-E", "-o", "command=", "-p", strconv.Itoa(pid)).Output()
		if err != nil {
			return env
		}
		for _, tok := range strings.Fields(string(out)) {
			if i := strings.IndexByte(tok, '='); i > 0 && strings.ToUpper(tok[:i]) == tok[:i] {
				env[tok[:i]] = tok[i+1:]
			}
		}
	}
	return env
}

// OpenFiles returns paths of regular files a process has open.
func OpenFiles(pid int) []string {
	var out []string
	if runtime.GOOS == "linux" {
		dir := "/proc/" + strconv.Itoa(pid) + "/fd"
		ents, err := os.ReadDir(dir)
		if err != nil {
			return nil
		}
		for _, e := range ents {
			if p, err := os.Readlink(filepath.Join(dir, e.Name())); err == nil && strings.HasPrefix(p, "/") {
				out = append(out, p)
			}
		}
		return out
	}
	if runtime.GOOS == "darwin" {
		b, err := exec.Command("lsof", "-p", strconv.Itoa(pid), "-Fn").Output()
		if err != nil {
			return nil
		}
		for _, l := range strings.Split(string(b), "\n") {
			if strings.HasPrefix(l, "n/") {
				out = append(out, l[1:])
			}
		}
	}
	return out
}

// StartTime approximates when a process started using ps etimes.
func StartTime(pid int) time.Time {
	out, err := exec.Command("ps", "-o", "etimes=", "-p", strconv.Itoa(pid)).Output()
	if err != nil {
		return time.Time{}
	}
	secs, err := strconv.Atoi(strings.TrimSpace(string(out)))
	if err != nil {
		return time.Time{}
	}
	return time.Now().Add(-time.Duration(secs) * time.Second)
}

// Cwd returns a process's working directory where the OS exposes it.
func Cwd(pid int) string {
	if runtime.GOOS == "linux" {
		if p, err := os.Readlink("/proc/" + strconv.Itoa(pid) + "/cwd"); err == nil {
			return p
		}
	}
	return ""
}
