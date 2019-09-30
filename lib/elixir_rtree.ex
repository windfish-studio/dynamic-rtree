defmodule ElixirRtree do
  alias ElixirRtree.Node
  alias ElixirRtree.Utils

  def new(width \\ 6, mode \\ :prod)do
    w = [{:min_width,:math.floor(width) / 2.0},{:max_width,width}]
    ets = :ets.new(:rtree,[:set])

    db = if mode == :dev, do: setup_dgraph


    node = Node.new()

    tree = %{
      :metadata => %{params: w, ets_table: ets, dgraph: db},
      :parents => %{},
      'root' => node,
       node => []
    }

    :ets.insert(ets,{:metadata,Map.get(tree,:metadata)})
    :ets.insert(ets,{'root', node ,:root})

    if db do
      root = %{
        "identifier" => "root",
        "childs" => [%{"identifier" => node,
                    "bounding" => Kernel.inspect([{0,0},{0,0}],charlists: false),
                    "childs" => []}]
      }

      Dlex.set(db,root)
    end

    :ets.insert(ets,{node,[{0,0},{0,0}],:node})
    tree
  end

  def setup_dgraph()do
    {:ok, pid} = Dlex.start_link(pool_size: 2)
    Dlex.alter!(pid, %{drop_all: true})

    schema = """
      <identifier>: string @index(hash) .
    """

    Dlex.alter!(pid, schema)
    pid
  end

  # Helpers

  def get_root(rbundle)do
    rbundle.tree |> Map.get('root')
  end

  def is_root?(rbundle,node)do
    get_root(rbundle) == node
  end

  def get_rbundle(tree)do
    meta = tree[:metadata]
    params = meta.params
    rbundle = %{
      tree: tree,
      max_width: params[:max_width],
      min_width: params[:min_width],
      ets: meta.ets_table,
      db: meta.dgraph,
      parents: tree[:parents]
    }
  end

  # Actions

  def insert(tree,{id,box} = leaf)do
    t1 = :os.system_time(:millisecond)
    rbundle = get_rbundle(tree)
    r = if rbundle.ets |> :ets.member(id) do
      IO.inspect "Impossible to insert, id value already exists: id's MUST be uniq"
      tree
    else
      path = best_subtree(rbundle,leaf)
      insertion(rbundle,path,leaf)
      |> recursive_update(tl(path),leaf,:insertion)
    end
    t2 = :os.system_time(:millisecond)
    IO.inspect t2-t1
    r
  end

  def query(tree,box)do
    t1 = :os.system_time(:millisecond)
    rbundle = get_rbundle(tree)
    r = find_match_leafs(rbundle,box,[get_root(rbundle)],[])
    t2 = :os.system_time(:millisecond)
    IO.inspect "#{t2-t1} ms"
    r
  end

  def delete(tree,id)do
    t1 = :os.system_time(:millisecond)
    rbundle = get_rbundle(tree)
    r = remove(rbundle,id)
    t2 = :os.system_time(:millisecond)
    IO.inspect "#{t2-t1} ms"
    r
  end

  # Internal actions
  ## Insert

  defp insertion(rbundle,branch,{id,box} = leaf)do

    tree_update = add_entry(rbundle,hd(branch),leaf)

    childs = tree_update |> Map.get(hd(branch))

    final_tree = if length(childs) > rbundle.max_width do
      handle_overflow(%{rbundle | tree: tree_update, parents: tree_update |> Map.get(:parents)},branch)
    else
      tree_update
    end

    %{rbundle | tree: final_tree}
  end

  defp add_entry(rbundle,node,{id,box} = _leaf)do
    :ets.insert(rbundle.ets,{id,box,:leaf})
    update_node_bbox(rbundle,node,box,:insertion)

    if rbundle.db do
      query = ~s|{ v as var(func: eq(identifier, "#{node}")) }|
      Dlex.mutate!(rbundle.db, query,
        ~s|uid(v) <childs> _:blank .
         _:blank <identifier> "#{id}" .
         _:blank <bounding> "#{Kernel.inspect(box,charlists: false)}" .|,return_json: true)
    end
    parents_update = rbundle.parents |> Map.put(id,node)

    rbundle.tree
    |> Map.update!(node,fn ch -> [id] ++ ch end)
    |> Map.put(:parents,parents_update)
    |> Map.put(id,:leaf)
  end

  # TODO: refactor pls
  defp handle_overflow(rbundle,branch)do
    n = hd(branch)

    {node_n,new_node} = split(rbundle,n)

    if is_root?(rbundle,n) do
      new_root = Node.new()
      root_bbox = Utils.combine_multiple([node_n.bbox,new_node.bbox])
      :ets.insert(rbundle.ets,{new_root,root_bbox,:node})
      update_crush(rbundle,n,{Utils.ets_index(:bbox),node_n.bbox})
      :ets.insert(rbundle.ets,{new_node.id,new_node.bbox,:node})
      if rbundle.db do
        Dlex.transaction(rbundle.db, fn conn ->
          query = ~s|{ v as var(func: eq(identifier, "root"))
                      x as var(func: eq(identifier, "#{node_n.id}"))}|
          Dlex.delete(rbundle.db, query,
            ~s|uid(v) <childs> uid(x) .|,return_json: true)

          query = ~s|{ v as var(func: eq(identifier, "root"))}|
          Dlex.mutate!(rbundle.db, query,
            ~s|uid(v) <childs> _:blank .
            _:blank <identifier> "#{new_root}".
            _:blank <bounding> "#{root_bbox |> Kernel.inspect(charlists: false)}" .|,return_json: true)

          query = ~s|{ v as var(func: eq(identifier, "#{new_root}"))
                      x as var(func: eq(identifier, ["#{node_n.id}","#{new_node.id}"]))}|
          Dlex.mutate!(rbundle.db, query,
            ~s|uid(v) <childs> uid(x) .|,return_json: true)
        end)
      end
      parents_update = rbundle.parents
                       |> Map.put(node_n.id,new_root)
                       |> Map.put(new_node.id,new_root)
      parents_update = new_node.childs |> Enum.reduce(parents_update,fn c,acc ->
        acc |> Map.put(c,new_node.id)
      end)
      rbundle.tree |> Map.put(new_node.id,new_node.childs)
      |> Map.replace!(n,node_n.childs)
      |> Map.replace!('root',new_root)
      |> Map.put(new_root,[node_n.id,new_node.id])
      |> Map.put(:parents,parents_update)
    else
      parent = hd(tl(branch))
      update_crush(rbundle,n,{Utils.ets_index(:bbox),node_n.bbox})
      :ets.insert(rbundle.ets,{new_node.id,new_node.bbox,:node})
      if rbundle.db do
        query = ~s|{ v as var(func: eq(identifier, "#{parent}"))
                    x as var(func: eq(identifier, "#{new_node.id}"))}|
        Dlex.mutate!(rbundle.db, query,
          ~s|uid(v) <childs> uid(x) .|,return_json: true)
      end
      parents_update = rbundle.parents |> Map.put(new_node.id,parent)
      parents_update = new_node.childs |> Enum.reduce(parents_update,fn c,acc ->
        acc |> Map.put(c,new_node.id)
      end)
      updated_tree = rbundle.tree
                     |> Map.put(new_node.id,new_node.childs)
                     |> Map.put(:parents,parents_update)
                     |> Map.replace!(n,node_n.childs)
                     |> Map.update!(parent,fn ch -> [new_node.id] ++ ch end)

      if length(updated_tree |> Map.get(parent)) > rbundle.max_width, do: handle_overflow(%{rbundle | tree: updated_tree, parents: parents_update},tl(branch)), else: updated_tree
    end
  end

  defp split(rbundle,node)do
    sorted_nodes = rbundle.tree
                   |> Map.get(node)
                   |> Enum.map(fn n ->
      bbox = rbundle.ets |> :ets.lookup(n) |> Utils.ets_value(:bbox)
      {bbox |> Utils.middle_value,n,bbox}
    end)
                   |> Enum.sort
                   |> Enum.map(fn {_x,y,z} -> {y,z} end)

    {n_id,n_bbox} = sorted_nodes
                    |> Enum.slice(0..((rbundle.max_width/2) - 1 |> Kernel.trunc)) |> Enum.unzip


    {dn_id,dn_bbox} = sorted_nodes
                      |> Enum.slice(((rbundle.max_width/2) |> Kernel.trunc)..length(sorted_nodes) - 1) |> Enum.unzip
    new_node = Node.new()

    n_bounds = n_bbox |> Utils.combine_multiple
    dn_bounds = dn_bbox |> Utils.combine_multiple
    if rbundle.db do
      Dlex.set(rbundle.db,%{
        "identifier" => new_node,
        "bounding" => "#{dn_bounds |> Kernel.inspect(charlists: false)}",
        "childs" => []
      })

      Dlex.transaction(rbundle.db, fn conn ->

        query = ~s|{ v as var(func: eq(identifier, "#{node}"))
                    c as var(func: eq(identifier, #{dn_id |> Kernel.inspect(charlists: false)}))}|
        Dlex.delete(rbundle.db, query,
          ~s|uid(v) <childs> uid(c) .
             uid(v) <bounding> "#{n_bounds |> Kernel.inspect(charlists: false)}" .|,return_json: true)


        query = ~s|{ v as var(func: eq(identifier, "#{new_node}"))
                    c as var(func: eq(identifier, #{dn_id |> Kernel.inspect(charlists: false)}))}|
        Dlex.mutate!(rbundle.db, query,
          ~s|uid(v) <childs> uid(c) .|,return_json: true)
      end)
    end
    {%{id: node, childs: n_id, bbox: n_bounds},
      %{id: new_node, childs: dn_id, bbox: dn_bounds}}
  end

  defp best_subtree(rbundle,leaf)do
    find_best_subtree(rbundle,get_root(rbundle),leaf,[])
  end

  defp find_best_subtree(rbundle,root,{_id,box} = leaf,track)do
    childs = rbundle.tree |> Map.get(root)
    type = rbundle.ets |> :ets.lookup(root) |> Utils.ets_value(:type)

    if is_list(childs) and length(childs) > 0 do
      index_result = get_best_candidate(rbundle,childs,box)
      find_best_subtree(rbundle,childs |> Enum.at(index_result),leaf,[root] ++ track)
    else
      if type === :leaf, do: track, else: [root] ++ track
    end
  end

  defp get_best_candidate(rbundle,candidates,box)do
    fits = candidates |> Enum.reduce_while(%{:area =>[] ,:enlargement => []},fn c,acc ->
      cbox = rbundle.ets |> :ets.lookup(c) |> Utils.ets_value(:bbox)
      area = Utils.overlap_area(box,cbox)
      new_acc = if area > 0, do: acc |> Map.delete(:enlargement), else: acc
      new_acc = new_acc |> Map.update!(:area, fn l -> l ++ [area] end)
      new_acc = if new_acc |> Map.has_key?(:enlargement)do
        new_acc |> Map.update!(:enlargement, fn l -> l ++ [Utils.enlargement_area(box,cbox)] end)
      else
        new_acc
      end
      area_list = new_acc |> Map.get(:area)
      n_c = length(area_list)
      if Enum.sum(area_list) >= 100/n_c, do: {:halt, new_acc}, else: {:cont, new_acc}
    end)

    {best_fit,list} = if fits |> Map.has_key?(:enlargement) do
      l = fits |> Map.get(:enlargement)
      {l |> Enum.min,l}
    else
      l = fits |> Map.get(:area)
      {l |> Enum.max,l}
    end

    list |> Enum.find_index(fn e -> e == best_fit end)
  end

  ## Query

  defp find_match_leafs(rbundle,box,dig,leafs)do
    f = hd(dig)
    tail = if length(dig) > 1, do: tl(dig), else: []
    fbox = rbundle.ets |> :ets.lookup(f) |> Utils.ets_value(:bbox)

    {new_dig,new_leafs} = if Utils.overlap?(fbox,box)do
        content = rbundle.tree |> Map.get(f)
        if is_atom(content), do: {tail,[f] ++ leafs}, else: {content ++ tail,leafs}
      else
        {tail,leafs}
    end

    if length(new_dig) > 0, do: find_match_leafs(rbundle,box,new_dig,new_leafs), else: new_leafs
  end

  ## Delete

  defp remove(rbundle,id)do

    parent = rbundle.parents |> Map.get(id)

    if parent do
      removed_bbox = rbundle.ets |> :ets.lookup(id) |> Utils.ets_value(:bbox)
      rbundle.ets |> :ets.delete(id)
      parents_update = rbundle.parents |> Map.delete(id)
      tree_updated = rbundle.tree |> Map.delete(id)
      |> Map.update!(parent,fn ch -> ch -- [id] end)
      |> Map.put(:parents,parents_update)
      if rbundle.db do
        query = ~s|{ v as var(func: eq(identifier, "#{parent}"))
                    x as var(func: eq(identifier, "#{id}"))}|
        Dlex.delete(rbundle.db, query,
          ~s|uid(v) <childs> uid(x) .|,return_json: true)
      end
      parent_childs = tree_updated |> Map.get(parent)

      if length(parent_childs) > 0 do
        %{rbundle | tree: tree_updated, parents: parents_update} |> recursive_update(parent,removed_bbox,:deletion)
      else
        remove(%{rbundle | tree: tree_updated, parents: parents_update},parent)
      end
    else
      if rbundle.db do
        query = ~s|{ v as var(func: eq(identifier, "#{id}"))}|
        Dlex.mutate!(rbundle.db, query,
          ~s|uid(v) <bounding> "#{[{0,0},{0,0}] |> Kernel.inspect(charlists: false)}" .|,return_json: true)
      end
      rbundle.ets |> :ets.update_element(id,{Utils.ets_index(:bbox),[{0,0},{0,0}]})
      rbundle.tree
    end
  end

  ## Common updates

  # Recursive bbox updates when you have node path from root (at insertion)
  defp recursive_update(rbundle,path,{_id,box} = leaf,:insertion)when length(path) > 0 do

    modified = update_node_bbox(rbundle,hd(path),box,:insertion)

    if modified and length(path) > 1, do: recursive_update(rbundle,tl(path),leaf,:insertion), else: rbundle.tree
  end

  # Typical dumbass safe method
  defp recursive_update(rbundle,_path,_leaf,:insertion)do
    rbundle.tree
  end

  # Recursive bbox updates when u dont have node path from root, so you have to query parents map... (at delete)
  defp recursive_update(rbundle,node,box,:deletion)do
    modified = update_node_bbox(rbundle,node,box,:deletion)
    next = rbundle.parents |> Map.get(node)
    if modified and next, do: recursive_update(rbundle,next,box,:deletion), else: rbundle.tree
  end

  defp update_node_bbox(rbundle,node,the_box,action)do
    node_box = rbundle.ets |> :ets.lookup(node) |> Utils.ets_value(:bbox)

    new_bbox = case action do
      :insertion -> Utils.combine(node_box,the_box)
      :deletion -> if Utils.in_border?(node_box,the_box) do
                      rbundle.tree |> Map.get(node)
                      |> Enum.map(fn c ->
                        rbundle.ets |> :ets.lookup(c) |> Utils.ets_value(:bbox) end)
                      |> Utils.combine_multiple
                    else
                      node_box
                    end
    end

    bbox_mutation(rbundle,node,new_bbox,node_box)
  end

  defp bbox_mutation(rbundle,node,new_bbox,node_box)do
    if new_bbox == node_box do
      false
    else
      if rbundle.db do
        Dlex.transaction(rbundle.db, fn conn ->
          query = ~s|{ v as var(func: eq(identifier, "#{node}"))}|
          Dlex.mutate!(rbundle.db, query,
            ~s|uid(v) <bounding> "#{new_bbox |> Kernel.inspect(charlists: false)}" .|,return_json: true)
        end)
      end
      rbundle.ets |> :ets.update_element(node,{Utils.ets_index(:bbox),new_bbox})
      true
    end
  end

  # Crush a value, not read needed.
  defp update_crush(rbundle,node,{pos,value} = val)do
    if rbundle.db do
      Dlex.transaction(rbundle.db, fn conn ->
        query = ~s|{ v as var(func: eq(identifier, "#{node}"))}|
        Dlex.mutate!(rbundle.db, query,
          ~s|uid(v) <bounding> "#{value |> Kernel.inspect(charlists: false)}" .|,return_json: true)
      end)
    end
    rbundle.ets |> :ets.update_element(node,val)
  end

end
