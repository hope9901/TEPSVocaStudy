import sqlite3
import os
import json
import time

try:
    import google.generativeai as genai
except ImportError:
    print("Error: The 'google-generativeai' library is not installed.")
    print("Please run: pip install google-generativeai")
    genai = None

DB_PATH = r"f:\project2\TEPSvoca\v85_20260312T133124Z.db"
MODEL_NAME = "gemini-2.5-flash"  # Use Gemini 2.5 Flash for vocabulary sentence generation
BATCH_SIZE = 40  # 40 words per prompt

def get_db_connection():
    return sqlite3.connect(DB_PATH)

def fetch_words_needing_sentences():
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.execute("""
        SELECT id, word, meaning 
        FROM Corpus 
        WHERE isDeleted = 0 
          AND (exampleSentence IS NULL OR exampleSentence = '')
        ORDER BY word;
    """)
    rows = cursor.fetchall()
    conn.close()
    return [{"id": r[0], "word": r[1], "meaning": r[2]} for r in rows]

def update_sentences_in_db(updates):
    conn = get_db_connection()
    cursor = conn.cursor()
    cursor.executemany("""
        UPDATE Corpus 
        SET exampleSentence = ?, updatedAt = datetime('now')
        WHERE id = ?;
    """, [(u['sentence'], u['id']) for u in updates])
    conn.commit()
    conn.close()

def generate_batch_sentences(model, batch):
    word_list_str = "\n".join([f"- {item['word']} ({item['meaning']})" for item in batch])
    
    prompt = f"""You are a TEPS (Test of English for International Communication) vocabulary expert.
Generate exactly ONE natural, academic, or business-related English example sentence for each of the target words listed below. 
The sentence should clearly illustrate the word's meaning and typical usage in a TEPS context.
Keep the sentences concise (usually 10-25 words) and advanced.

Target Words:
{word_list_str}

You MUST respond ONLY with a raw JSON array of objects. Do not include any markdown wrappers (like ```json ... ```), explanations, or trailing text.
The JSON format must strictly match this structure:
[
  {{"word": "word1", "sentence": "Example sentence for word1."}},
  {{"word": "word2", "sentence": "Example sentence for word2."}}
]
"""

    max_retries = 5
    base_delay = 5  # Base delay in seconds for exponential backoff (due to free tier RPM limits)
    
    for attempt in range(max_retries):
        try:
            response = model.generate_content(
                prompt,
                generation_config=genai.GenerationConfig(
                    response_mime_type="application/json",
                    temperature=0.3
                )
            )
            
            content = response.text.strip()
            # Clean markdown codeblock if returned
            if content.startswith("```"):
                lines = content.split("\n")
                if lines[0].startswith("```json") or lines[0].startswith("```"):
                    content = "\n".join(lines[1:-1]).strip()
                    
            results = json.loads(content)
            
            updates = []
            word_to_id = {item['word'].lower().strip(): item['id'] for item in batch}
            
            for res in results:
                w_clean = res.get('word', '').lower().strip()
                sentence = res.get('sentence', '').strip()
                if w_clean in word_to_id and sentence:
                    updates.append({
                        "id": word_to_id[w_clean],
                        "sentence": sentence
                    })
            return updates
            
        except Exception as e:
            print(f"API call failed (Attempt {attempt+1}/{max_retries}): {e}")
            if attempt < max_retries - 1:
                sleep_time = base_delay * (2 ** attempt)
                print(f"Waiting for {sleep_time} seconds before retrying...")
                time.sleep(sleep_time)
            else:
                print("Max retries reached. Skipping this batch.")
                return []

def main():
    if not genai:
        return

    # Try to load GEMINI_API_KEY from .env file if not set in environment
    if not os.environ.get("GEMINI_API_KEY"):
        env_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), ".env")
        if os.path.exists(env_path):
            try:
                with open(env_path, "r", encoding="utf-8") as f:
                    for line in f:
                        line_strip = line.strip()
                        if line_strip.startswith("GEMINI_API_KEY="):
                            parts = line_strip.split("=", 1)
                            if len(parts) == 2:
                                val = parts[1].strip().strip('"').strip("'")
                                os.environ["GEMINI_API_KEY"] = val
                                break
            except Exception as e:
                print(f"Error reading .env file: {e}")

    api_key = os.environ.get("GEMINI_API_KEY")
    if not api_key:
        print("Error: GEMINI_API_KEY environment variable is not set.")
        print("Please obtain a free API key from Google AI Studio (https://aistudio.google.com/)")
        print("Then set it in your environment. Example:")
        print("  Windows PowerShell: $env:GEMINI_API_KEY='your-free-api-key'")
        print("  Windows CMD: set GEMINI_API_KEY=your-free-api-key")
        return

    # Configure Gemini API
    genai.configure(api_key=api_key)
    model = genai.GenerativeModel(MODEL_NAME)
    
    words = fetch_words_needing_sentences()
    total_words = len(words)
    print(f"Total active words needing example sentences: {total_words}")
    
    if total_words == 0:
        print("All words already have example sentences!")
        return

    completed = 0
    start_time = time.time()
    
    # Using a larger delay between batches because the free tier limit is 15 RPM
    for i in range(0, total_words, BATCH_SIZE):
        batch = words[i:i+BATCH_SIZE]
        print(f"Processing batch {i//BATCH_SIZE + 1} ({len(batch)} words: '{batch[0]['word']}' to '{batch[-1]['word']}')...")
        
        updates = generate_batch_sentences(model, batch)
        if updates:
            update_sentences_in_db(updates)
            completed += len(updates)
            print(f"Successfully updated {len(updates)} sentences in DB. Total progress: {completed}/{total_words}")
        else:
            print(f"Failed to generate sentences for this batch. Skipping...")
        
        # Sleep to stay within Gemini free tier rate limits (15 RPM -> ~4 seconds delay)
        time.sleep(5)
        
    end_time = time.time()
    print(f"\nAll done! Generated {completed} example sentences in {end_time - start_time:.2f} seconds.")

if __name__ == "__main__":
    main()
