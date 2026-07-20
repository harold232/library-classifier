# 📚 Library Organizer

Library Organizer is a PowerShell-based tool that automatically organizes PDF libraries using configurable JSON rules.

Instead of hardcoding categories, keywords, or authors into the script, all classification logic is stored in external rule files, making the organizer fully customizable.

---

# Features

- Organizes thousands of PDF books automatically.
- Uses configurable JSON rule files.
- Supports multiple knowledge categories.
- Matches by:
  - Keywords
  - Authors
- Priority-based rule selection.
- Automatic folder creation.
- Simulation mode (dry run).
- Copy or Move mode.
- Recursive directory scanning.
- Automatic duplicate filename handling.
- CSV logs.
- Statistics by category.
- Rule usage reports.
- Unmatched files report.
- Undo the last organization operation.

---

# Project Structure

```
LibraryOrganizer/
│
├── organize.ps1
├── config.json
│
├── rules/
│   ├── rules-ai.json
│   ├── rules-business.json
│   ├── rules-cloud-devops.json
│   ├── rules-computer-science.json
│   ├── rules-certifications.json
│   ├── rules-cybersecurity.json
│   ├── rules-data-science.json
│   ├── rules-design.json
│   ├── rules-hobbies.json
│   ├── rules-interview-prep.json
│   ├── rules-languages.json
│   ├── rules-mathematics.json
│   ├── rules-office.json
│   ├── rules-preuniversity.json
│   ├── rules-programming.json
│   ├── rules-research.json
│   ├── rules-science.json
│   └── rules-software-engineering.json
│
└── logs/
```

---

# Configuration

All settings are read from `config.json`.

Example:

```json
{
    "SourcePath": "D:\\Biblioteca",
    "DestinationPath": "D:\\Library",

    "RulesPath": ".\\rules",
    "LogPath": ".\\logs",

    "Simulation": true,
    "Copy": false,
    "Recurse": true,

    "IncludeNonPdf": false,
    "CreateFolders": true,
    "UnmatchedFolder": "Archive/Unmatched"
}
```

---

# Configuration Options

| Option | Description |
|----------|-------------|
| SourcePath | Folder containing the files to organize |
| DestinationPath | Destination library |
| RulesPath | Folder containing all rule files |
| LogPath | Folder where reports are generated |
| Simulation | Runs without moving files |
| Copy | Copies files instead of moving |
| Recurse | Searches subfolders |
| IncludeNonPdf | Include non-PDF files |
| CreateFolders | Automatically create destination folders |
| UnmatchedFolder | Folder for unmatched files |

---

# Rule Format

Each rule file contains one or more categories.

Example:

```json
{
    "AI": [
        {
            "folder": "AI/Machine Learning",
            "priority": 120,
            "keywords": [
                "machine learning",
                "deep learning",
                "neural networks"
            ],
            "authors": [
                "bishop",
                "goodfellow"
            ]
        }
    ]
}
```

---

# Rule Selection

When multiple rules match the same file, the organizer chooses the best one using the following order:

1. Highest priority
2. Author matches
3. Number of keyword matches
4. Longest total matched text

---

# Running

Simulation:

```powershell
.\organize.ps1
```

With

```json
"Simulation": true
```

nothing is moved.

---

Real organization:

```json
"Simulation": false
```

Then execute:

```powershell
.\organize.ps1
```

---

# Copy Mode

```json
"Copy": true
```

Files are copied instead of moved.

---

# Duplicate Files

If the destination already contains:

```
Clean Code.pdf
```

the organizer automatically creates

```
Clean Code (2).pdf
```

instead of overwriting the existing file.

---

# Automatic Folder Creation

Folders defined by the matching rule are automatically created when they do not already exist.

Example:

```
AI/
    Machine Learning/
```

No manual folder creation is required.

---

# Logs

Every execution generates several CSV reports.

```
logs/
```

Example:

```
organize-move-20250719.csv
```

Contains every processed file.

---

```
categories-20250719.csv
```

Summary by category.

---

```
rule-usage-20250719.csv
```

Shows which rules matched the most files.

---

```
unmatched-20250719.csv
```

Lists files that did not match any rule.

---

# Undo

The last move operation can be reverted.

```powershell
.\organize.ps1 -UndoLast
```

The undo operation uses the latest movement log.

---

# Matching Process

For every file the organizer:

1. Reads the filename.
2. Normalizes text.
3. Removes accents.
4. Removes punctuation.
5. Converts to lowercase.
6. Compares against every rule.
7. Scores each rule.
8. Chooses the best match.
9. Creates destination folders if needed.
10. Moves or copies the file.
11. Writes logs.

---

# Requirements

- Windows
- PowerShell 5.1 or later

---

# License

MIT License.