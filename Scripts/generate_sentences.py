import sqlite3
import os
import json
import time
from concurrent.futures import ThreadPoolExecutor

# Try to import anthropic, prompt user if not installed
try:
    import anthropic
except ImportError:
    print("Error: The 'anthropic' library is not installed. Please run 'pip install anthropic' first.")
    # We will write a placeholder print but continue compilation
    anthropic = None

DB_PATH = r"f:\project2\TEPSvoca\v85_20260312T133124Z.db"
MODEL_NAME = "claude-3-5-sonnet-20240620"
BATCH_SIZE = 40  # Process 40 words per prompt to balance context size and response limits

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

def generate_batch_sentences(client, batch):
    # Prepare the prompt
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

    try:
        response = client.messages.create(
            model=MODEL_NAME,
            max_tokens=4000,
            temperature=0.3,
            system="You are a strict JSON generator. You output only raw, valid JSON arrays. Do not add conversational text or markdown formatting.",
            messages=[
                {"role": "user", "content": prompt}
            ]
        )
        
        content = response.content[0].text.strip()
        # Clean markdown codeblock formatting if Claude added it despite instructions
        if content.startswith("```"):
            lines = content.split("\n")
            if lines[0].startswith("```json") or lines[0].startswith("```"):
                content = "\n".join(lines[1:-1]).strip()
                
        results = json.loads(content)
        
        # Map results back to IDs
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
        print(f"Error generating sentences for batch starting with '{batch[0]['word']}': {e}")
        return []

def main():
    if not anthropic:
        print("Please install the anthropic package and try again.")
        return

    api_key = os.environ.get("ANTHROPIC_API_KEY")
    if not api_key:
        print("Error: ANTHROPIC_API_KEY environment variable is not set.")
        print("Please set it in your environment. Example:")
        print("  Windows PowerShell: $env:ANTHROPIC_API_KEY='your-api-key'")
        print("  Windows CMD: set ANTHROPIC_API_KEY=your-api-key")
        return

    client = anthropic.Anthropic(api_key=api_key)
    
    words = fetch_words_needing_sentences()
    total_words = len(words)
    print(f"Total active words needing example sentences: {total_words}")
    
    if total_words == 0:
        print("All words already have example sentences!")
        return

    # Process in batches
    completed = 0
    start_time = time.time()
    
    for i in range(0, total_words, BATCH_SIZE):
        batch = words[i:i+BATCH_SIZE]
        print(f"Processing batch {i//BATCH_SIZE + 1} ({len(batch)} words: '{batch[0]['word']}' to '{batch[-1]['word']}')...")
        
        updates = generate_batch_sentences(client, batch)
        if updates:
            update_sentences_in_db(updates)
            completed += len(updates)
            print(f"Successfully updated {len(updates)} sentences in DB. Total progress: {completed}/{total_words}")
        else:
            print(f"Failed to generate sentences for this batch. Skipping...")
        
        # Sleep briefly to respect rate limits
        time.sleep(1)
        
    end_time = time.time()
    print(f"\nAll done! Generated {completed} example sentences in {end_time - start_time:.2f} seconds.")

if __name__ == "__main__":
    main()
