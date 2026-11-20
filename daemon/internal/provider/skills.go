// Package provider holds types shared by the Claude and Codex integrations.
package provider

import (
	"bufio"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// Skill is a slash-command the user can type into a session.
type Skill struct {
	Name        string `json:"name"` // without the leading slash
	Description string `json:"description,omitempty"`
	Source      string `json:"source"` // user|project|plugin|builtin
	Provider    string `json:"provider"`
	Path        string `json:"path,omitempty"`
}

// ReadFrontmatter extracts name and description from a SKILL.md / command
// file's YAML frontmatter. Missing frontmatter yields empty strings.
func ReadFrontmatter(path string) (name, desc string) {
	f, err := os.Open(path)
	if err != nil {
		return "", ""
	}
	defer f.Close()
	sc := bufio.NewScanner(f)
	sc.Buffer(make([]byte, 64*1024), 64*1024)
	if !sc.Scan() || strings.TrimSpace(sc.Text()) != "---" {
		return "", ""
	}
	for sc.Scan() {
		l := sc.Text()
		if strings.TrimSpace(l) == "---" {
			break
		}
		k, v, ok := strings.Cut(l, ":")
		if !ok {
			continue
		}
		v = strings.Trim(strings.TrimSpace(v), `"'`)
		switch strings.TrimSpace(k) {
		case "name":
			name = v
		case "description":
			desc = v
		}
	}
	return name, desc
}

// SkillDirs collects <dir>/*/SKILL.md entries.
func SkillDirs(dir, source, prov string) []Skill {
	var out []Skill
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	for _, e := range ents {
		if !e.IsDir() {
			continue
		}
		p := filepath.Join(dir, e.Name(), "SKILL.md")
		if _, err := os.Stat(p); err != nil {
			continue
		}
		n, d := ReadFrontmatter(p)
		if n == "" {
			n = e.Name()
		}
		out = append(out, Skill{Name: n, Description: d, Source: source, Provider: prov, Path: p})
	}
	return out
}

// CommandFiles collects <dir>/*.md command entries (Claude "commands").
func CommandFiles(dir, source, prov string) []Skill {
	var out []Skill
	ents, err := os.ReadDir(dir)
	if err != nil {
		return nil
	}
	for _, e := range ents {
		if e.IsDir() || !strings.HasSuffix(e.Name(), ".md") {
			continue
		}
		p := filepath.Join(dir, e.Name())
		_, d := ReadFrontmatter(p)
		out = append(out, Skill{Name: strings.TrimSuffix(e.Name(), ".md"), Description: d, Source: source, Provider: prov, Path: p})
	}
	return out
}

// Dedupe removes repeated names, keeping the first, and sorts by name.
func Dedupe(in []Skill) []Skill {
	seen := map[string]bool{}
	var out []Skill
	for _, s := range in {
		key := s.Provider + "/" + s.Name
		if seen[key] {
			continue
		}
		seen[key] = true
		out = append(out, s)
	}
	sort.Slice(out, func(i, j int) bool { return out[i].Name < out[j].Name })
	return out
}
