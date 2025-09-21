# Hinge Agent 🤖
Note: This is configured for my iphone (Iphone pro max 13) and thus you may run into issues with different frame iphones. It should not be too much of a hassle to change this. The only hardcoded parts of the code is the button clicking (heart) or swipe right. Everything else is Apple vision algos. There's probably a way to have the heart icon identified but not yet implemented. Most of this readme is Claude code generated. Apologies in advance.

## TLDR
you need iphone screen mirroring, Grok API key (if you want the API key), saves stuff to Documents filepath 

Once a profile is saved, you can retroactively run API calls (if you want to test various prompts instead of waiting for the scrolling to occur). 

### There's two modes: one that actually utilizes AI and another 'dumb' mode that will just scroll down to the bottom of a profile and always swipe right. Use it if you don't want to spend money on API requests?

An AI-powered automated Hinge dating app bot that uses cutting-edge vision APIs to analyze profiles and make intelligent swiping decisions. Features dual AI provider support with OpenAI GPT-4o Vision and xAI's Grok Vision API.

Requirements
1. **macOS Sequoia** or later (required for iPhone Mirroring and Vision Framework)
2. **iPhone** with iOS 15+ connected and paired with your Mac
3. **AI API Access**: Choose one or both:
   - **OpenAI API key** with GPT-4o Vision access
   - **xAI API key** with Grok Vision access
4. **Sufficient disk space** for session photo storage (sessions can be 50-200MB each)
5. **Xcode Command Line Tools**: For Swift compilation

## 🚀 Installation

### Step 1: System Requirements
```bash
# Install Xcode command line tools
xcode-select --install

# Verify macOS version (must be Sequoia or later)
sw_vers
```
(or just go to Apple icon > About this Mac)

### Step 2: iPhone Mirroring Setup
1. **System Setup:**
   - Open System Settings > Apple ID > Media & Purchases
   - Enable iPhone Mirroring
   - Connect your iPhone 

2. **Test iPhone Mirroring:**
   - Open iPhone Mirroring app from Applications
   - Verify you can see and control your iPhone screen
   - Open Hinge on your iPhone through mirroring

### Step 3: API Keys Setup

**Option A: OpenAI (Don't Use, Too PC)**
```bash
# Get API key from https://platform.openai.com/
export OPENAI_API_KEY="sk-your-openai-api-key-here"

# Add to your shell profile for persistence
echo 'export OPENAI_API_KEY="sk-your-openai-api-key-here"' >> ~/.zshrc
```

**Option B: xAI Grok (Goat)**
```bash
# Get API key from https://x.ai/api
export XAI_API_KEY="xai-your-api-key-here"

# Add to your shell profile for persistence  
echo 'export XAI_API_KEY="xai-your-api-key-here"' >> ~/.zshrc
#
```
 I don't think the echo commands work but the regular export does 

### Step 4: Python Dependencies (don't need openai installation skip it model is hella pussy)
```bash
# Install required packages for AI integration
pip3 install openai requests --break-system-packages

# Verify installation
python3 -c "import openai, requests; print('Dependencies installed successfully')"
```

### Step 5: Compile and Test  (the test is pointless just skip this step honestly )
```bash
# Compile the agent
swiftc -o hinge_agent_v2 hinge_agent.swift

# Test compilation
./hinge_agent_v2 --test
```

## 🎯 Usage

### Basic Operation (USE THE GROK COMMAND)
```bash
# AI-powered swiping with OpenAI (default)
./hinge_agent_v2
# AI-powered swiping with Grok Vision

./hinge_agent_v2 --grok

# Manual decisions with AI analysis (recommended for testing)
./hinge_agent_v2 --dumb
```


### Advanced Options
```bash
# Enhanced photo processing
./hinge_agent_v2 --dedupe                    # Remove duplicate photos
./hinge_agent_v2 --filter                    # Auto-pass profiles with <2 solo photos
./hinge_agent_v2 --threshold 0.3             # Custom duplicate detection sensitivity

# Combined flags
./hinge_agent_v2 --grok --dumb --dedupe      # Grok + manual + deduplication
```

### Test and Analysis Modes
```bash
# Test vision APIs on existing sessions
python3 openai_vision_processor.py --test-session session_2025-09-11_14-51-22
python3 grok_vision_processor.py --test-session session_2025-09-11_14-51-22

# Compare AI providers on same profile
python3 openai_vision_processor.py --test-session session_id --criterion "attractive and compatible"
python3 grok_vision_processor.py --test-session session_id --criterion "attractive and compatible"
```

## 🤖 How It Works

### AI-Powered Decision Flow
1. **Profile Collection**: Scrolls through entire profile collecting photos and text
2. **Photo Organization**: Categorizes into `person/`, `multi_person/`, and `other/` folders  
3. **Person Detection**: Uses Vision Framework to identify solo vs multi-person photos
4. **Duplicate Removal**: Advanced neural network matching removes duplicate/cropped photos
5. **AI Analysis**: Sends photos to OpenAI GPT-4o or Grok Vision with academic research prompt
6. **Decision Making**: AI returns YES/NO with reasoning and confidence score
7. **Action Execution**: Swipes right (YES) or left (NO) based on AI decision

### Technical Features
- **Complete Profile Scrolling**: Automatically detects bottom of profile using screenshot comparison
- **Smart Photo Extraction**: Saliency-based extraction eliminates UI overlays and text
- **Advanced Person Detection**: Distinguishes solo photos from group photos for better analysis
- **Real-time Duplicate Detection**: Prevents saving duplicate photos during extraction
- **Session-based Storage**: Organized timestamped folders with comprehensive metadata
- **Academic Research Prompts**: Designed to maximize AI compliance and response quality

## 🔧 Configuration
You can play around more in-depth with the configs of this project in the config.json file. This is the default: 
```json{
  "defaults": {
    "visionProvider": "grok",
    "scrollDelay": 0.4,
    "duplicateDetection": true,
    "duplicateThreshold": 0.4,
    "markMode": false,
    "filterMode": false,
    "testMode": false,
    "dumbMode": false,
    "aestheticMode": true
  },
  "initialization": {
    "analysisType": "both",
    "userCriteria": "",
    "skipSetup": false
  },
  "ui": {
    "aestheticOutput": {
      "scrolling": "Scrolling...",
      "thinking": "Thinking...",
      "swipingRight": "Swiping Right",
      "swipingLeft": "Swiping Left"
    }
  }
}
```

### Customization Options
- **Provider Selection**: `--openai` or `--grok` flags
- **Analysis Criterion**: Editable in `hinge_agent.swift` line ~1680
- **Duplicate Threshold**: `--threshold 0.3` (lower = more sensitive)
- **Filtering**: `--filter` flag for strict profile requirements

## 📁 Session Data Structure

```
~/Documents/HingeAgentSessions/
├── session_2025-09-11_14-30-15/
│   ├── photos/
│   │   ├── person/                    # Solo person photos (AI analyzed)
│   │   ├── multi_person/              # Group photos + auto-cropped versions  
│   │   └── other/                     # Scenery, objects, text screenshots
│   ├── profile_data.json              # Complete profile with AI analysis
│   ├── openai_analysis.json           # OpenAI results (if used)
│   ├── grok_analysis.json             # Grok results (if used)  
│   └── NOT_LIVE_*_CALL_*/             # Test analysis folders
└── session_2025-09-11_15-45-22/       # Next session
```

## 🐛 Troubleshooting

### API Issues
```bash
# Test API keys
python3 -c "import os; print('OpenAI:', bool(os.getenv('OPENAI_API_KEY')))"
python3 -c "import os; print('xAI:', bool(os.getenv('XAI_API_KEY')))"

# Test API connectivity
python3 openai_vision_processor.py --test-session existing_session_id
python3 grok_vision_processor.py --test-session existing_session_id
```

### Vision Framework Issues
- Ensure macOS Sequoia or later
- Restart iPhone Mirroring if capture fails
- Check console for Vision Framework errors

### Photo Processing Issues
```bash
# Test with different duplicate thresholds
./hinge_agent_v2 --dedupe --threshold 0.2    # More sensitive
./hinge_agent_v2 --dedupe --threshold 0.5    # Less sensitive

# Use mark mode to test duplicate detection
./hinge_agent_v2 --dedupe --mark-mode
```

### AI Decision Issues
- Check API key validity and billing status
- Monitor console for AI reasoning and confidence scores
- Use `--dumb` mode to see AI analysis before swiping
- Test with existing sessions to verify AI integration

## 🔒 Privacy & Security

- **Local Processing**: All OCR and image extraction on your Mac
- **API Security**: Only sends base64 encoded photos to AI providers
- **Session Isolation**: Each profile analysis stored in separate timestamped folders
- **Secure Storage**: API keys use system environment variables
## 📝 License

Shield: [![CC BY 4.0][cc-by-shield]][cc-by]

This work is licensed under a
[Creative Commons Attribution 4.0 International License][cc-by].

[![CC BY 4.0][cc-by-image]][cc-by]

[cc-by]: http://creativecommons.org/licenses/by/4.0/
[cc-by-image]: https://i.creativecommons.org/l/by/4.0/88x31.png
[cc-by-shield]: https://img.shields.io/badge/License-CC%20BY%204.0-lightgrey.svg
## 🔗 Related Documentation

- [OpenAI Integration Guide](OPENAI_INTEGRATION_GUIDE.md) - Detailed OpenAI setup
- [Grok Integration Guide](GROK_INTEGRATION_GUIDE.md) - Detailed xAI Grok setup  
- [Claude Code Documentation](CLAUDE.md) - Technical implementation details
