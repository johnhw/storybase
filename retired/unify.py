import operator

# Mapping of supported operators for Python expressions
OPERATORS = {
    '>': operator.gt,
    '<': operator.lt,
    '>=': operator.ge,
    '<=': operator.le,
    '+': operator.add,
    '-': operator.sub,
    '*': operator.mul,
    '/': operator.truediv,
    'in': lambda x, y: x in y,
    'not-in': lambda x, y: x not in y,
    'len': lambda x: len(x),
    'count': lambda lst, elem: lst.count(elem)
}

def query(goal, facts, rules, substitutions=None):
    if substitutions is None:
        substitutions = {}

    # Try facts first
    for fact in facts:
        result = unify(goal, fact, substitutions.copy())
        if result is not None:
            yield result

    # Try rules
    for head, body in rules:
        result = unify(goal, head, substitutions.copy())
        if result is not None:
            yield from resolve_body(body, result, facts, rules)

def resolve_body(body, substitutions, facts, rules):
    if not body:  # Base case: empty body means success
        yield substitutions
    else:
        first = apply_subs(body[0], substitutions)

        if is_python_expression(first):
            # Handle Python expression
            if evaluate_expression(first, substitutions):
                yield from resolve_body(body[1:], substitutions, facts, rules)
        else:
            # Treat as logic goal
            for result in query(first, facts, rules, substitutions):
                yield from resolve_body(body[1:], result, facts, rules)

def unify(x, y, substitutions):
    if x == y:
        return substitutions

    if is_variable(x):
        return unify_variable(x, y, substitutions)

    if is_variable(y):
        return unify_variable(y, x, substitutions)

    if isinstance(x, list) and isinstance(y, list) and len(x) == len(y):
        for xi, yi in zip(x, y):
            substitutions = unify(xi, yi, substitutions)
            if substitutions is None:
                return None
        return substitutions

    return None

def unify_variable(var, value, substitutions):
    if var in substitutions:
        return unify(substitutions[var], value, substitutions)

    if is_variable(value) and value in substitutions:
        return unify(var, substitutions[value], substitutions)

    substitutions[var] = value
    return substitutions

def is_variable(x):
    return isinstance(x, str) and x.startswith('?')

def apply_subs(term, substitutions):
    if is_variable(term) and term in substitutions:
        return apply_subs(substitutions[term], substitutions)
    elif isinstance(term, list):
        return [apply_subs(t, substitutions) for t in term]
    else:
        return term

def is_python_expression(term):
    """Checks if a term is a Python expression, e.g., ['>', '?x', 20] or ['count', '?list', '?elem', '?count']."""
    return isinstance(term, list) and (term[0] in OPERATORS or term[0] == 'len')

def evaluate_expression(expression, substitutions):
    """Evaluates a Python expression after applying substitutions."""
    op = expression[0]
    
    if op == 'len':
        # Handle len as a special case with two arguments
        list_var, length_var = expression[1], expression[2]
        list_value = apply_subs(list_var, substitutions)
        length_value = OPERATORS['len'](list_value)
        return unify(length_value, apply_subs(length_var, substitutions), substitutions)
    
    if op == 'count':
        # Handle count as a special case with three arguments: list, element, and count variable
        list_var, elem_var, count_var = expression[1], expression[2], expression[3]
        list_value = apply_subs(list_var, substitutions)
        elem_value = apply_subs(elem_var, substitutions)
        count_value = OPERATORS['count'](list_value, elem_value)
        return unify(count_value, apply_subs(count_var, substitutions), substitutions)

    # For other operators, use the operator on the substituted values
    left_value = apply_subs(expression[1], substitutions)
    right_value = apply_subs(expression[2], substitutions)
    return OPERATORS[op](left_value, right_value)

# Facts and rules as lists
facts = [
    ['parent', 'john', 'mary'],
    ['parent', 'mary', 'susan'],
    ['age', 'john', 55],
    ['age', 'mary', 30],
    ['age', 'susan', 5],
    ['children', 'john', ['mary', 'mike', 'mary']],
    ['children', 'mary', ['susan']]
]

rules = [
    # grandparent(X, Y) :- parent(X, Z), parent(Z, Y)
    (['grandparent', '?x', '?y'], [['parent', '?x', '?z'], ['parent', '?z', '?y']]),
    # elder(X) :- age(X, A), A > 50
    (['elder', '?x'], [['age', '?x', '?a'], ['>', '?a', 50]]),
    # young(X) :- age(X, A), A < 20
    (['young', '?x'], [['age', '?x', '?a'], ['<', '?a', 20]]),
    # has_many_children(X) :- children(X, L), len(L, N), N > 1
    (['has_many_children', '?x'], [['children', '?x', '?l'], ['len', '?l', '?n'], ['>', '?n', 1]]),
    # child_is(X, Y) :- children(X, L), in(Y, L)
    (['child_is', '?x', '?y'], [['children', '?x', '?l'], ['in', '?y', '?l']]),
    # child_count(X, Y, C) :- children(X, L), count(L, Y, C)
    (['child_count', '?x', '?y', '?c'], [['children', '?x', '?l'], ['count', '?l', '?y', '?c']])
]

# Query: Who are John's grandchildren?
query_goal = ['grandparent', 'john', '?x']
print("Query: Who are John's grandchildren?")
for result in query(query_goal, facts, rules):
    print(result)

# Query: Who is elder?
query_goal = ['elder', '?x']
print("\nQuery: Who is elder?")
for result in query(query_goal, facts, rules):
    print(result)

# Query: Who is young?
query_goal = ['young', '?x']
print("\nQuery: Who is young?")
for result in query(query_goal, facts, rules):
    print(result)

# Query: Who has many children?
query_goal = ['has_many_children', '?x']
print("\nQuery: Who has many children?")
for result in query(query_goal, facts, rules):
    print(result)

# Query: Is Mary one of John's children?
query_goal = ['child_is', 'john', 'mary']
print("\nQuery: Is Mary one of John's children?")
for result in query(query_goal, facts, rules):
    print(result)

# Query: How many times does Mary appear as John's child?
query_goal = ['child_count', 'john', 'mary', '?count']
print("\nQuery: How many times does Mary appear as John's child?")
for result in query(query_goal, facts, rules):
    print(result)