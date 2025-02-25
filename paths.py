def find_paths(nested_dict, query):
    """
    Given a nested dictionary and a query string (with tokens separated by dots),
    return all matching paths through the dictionary as a list of tuples.
    
    The query string supports:
      - Literals: e.g., "cat"
      - Choices: e.g., "{cat|dog}"
      - Single-level wildcards: "*"
      - Optional (maybe present): "?"
      - Glob wildcards: "**" (matches any sequence of keys, including empty)
      - Negation: e.g., "!temp" or "!{cat|dog}" to match keys that are not the given literal/choice.
      - End anchor: "$" to force the match to end at a non-dict (leaf) value.
    """
    
    # Split the query into tokens (assumes tokens do not include dots inside choices)
    tokens = query.split(".")
    results = []
    
    def _matches(token, key):
        """Return True if key matches the token specifier."""
        # Handle negation tokens
        if token.startswith("!"):
            inner = token[1:]
            # Negated wildcard: unlikely to be useful but handled for completeness
            if inner == "*":
                return False
            if inner.startswith("{") and inner.endswith("}"):
                options = inner[1:-1].split("|")
                return key not in options
            return key != inner

        # Regular tokens
        if token == "*":
            return True
        if token.startswith("{") and token.endswith("}"):
            options = token[1:-1].split("|")
            return key in options
        # literal match
        return token == key

    def _search(d, tokens, path):
        # When no tokens remain, we've matched a complete pattern.
        if not tokens:
            results.append(path)
            return
         # Take the first token.
        token = tokens[0]
        remaining = tokens[1:]
        if token == "$":
            if remaining:
                raise ValueError("End anchor '$' must be the last token in the query.")
            # Only add the path if d is not a dict (i.e. a terminal value).
            if not isinstance(d, dict):
                results.append(path)
            return

        # If d is not a dict, no further keys can be matched.
        if not isinstance(d, dict):
            return

       
        
        # Special handling for end anchor: "$" must be the last token.
        

        if token == "**":
            # Option 1: Glob matches nothing (i.e., skip this token)
            _search(d, remaining, path)
            # Option 2: For each key, descend while staying on the glob token
            for key, value in d.items():
                _search(value, tokens, path + (key,))
        elif token == "?":
            # "Maybe present": Option to skip this token (do not descend)
            _search(d, remaining, path)
            # Also try matching any one key
            for key, value in d.items():
                _search(value, remaining, path + (key,))
        else:
            # For literal, choice, wildcard, or negation tokens, match exactly one key.
            for key, value in d.items():
                if _matches(token, key):
                    _search(value, remaining, path + (key,))
    
    _search(nested_dict, tokens, ())
    return results
# Example usage:
if __name__ == "__main__":
    # A sample nested dictionary:
    sample = {
        "cat": {
            "leg": {
                "toe": 1,
                "width": 2,
            },
            "arm": {
                "length": 3
            },
            "tail": {
                "length": 10
            },
            "temp": {
                "value": 99
            }
        },
        "dog": {
            "leg": {
                "toe": 3,
                "width": 4,
            }
        },
        "bird": {
            "wing": {
                "width": 5
            }
        }
    }
    
    queries = [
        "cat.leg.toe",           # literal path
        "cat.*.toe",             # wildcard in the second level
        "cat.**",                # glob from "cat"
        "**.width",              # any path ending with width
        "{cat|dog}.leg.width",   # choice between cat or dog
        "cat.?.?.{toe|tooth}",    # maybe present tokens
        "cat.leg.!toe",     # negation: skip "temp" key under cat
        "cat.leg.toe.$",         # end anchor: only match if toe is terminal
        "**.toe.$",
        "cat.leg",
        "cat.leg.$",
    ]
    
    for q in queries:
        print(f"Query: {q}")
        for path in find_paths(sample, q):
            print("  Path:", path)